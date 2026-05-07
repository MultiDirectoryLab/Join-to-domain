#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive script to rename a computer and/or join it to a Kerberos realm
    via the MultiDirectory REST API (v2.8.0e-01).

.DESCRIPTION
    A) Displays current computer name and optionally renames it (reboot deferred).
    B) Joins a Kerberos realm:
         1. Prompts for realm name and admin credentials.
         2. Discovers realm KDC via DNS SRV lookup; authenticates via cookie session.
         3. Creates a host principal (AES256-SHA1 + AES128-SHA1) with a
            strong random password (12-32 chars).
         4. Sets the computer password via  ksetup /setcomputerpassword.
         5. Configures the realm via  ksetup /setrealm  +  ksetup /addkdc.
         6. Updates the IPv4 DNS suffix search list.
    At the end the script asks whether to reboot immediately.

.NOTES
    API:  POST /api/auth/                   - form-urlencoded login (cookie session)
          POST /api/kerberos/principal       - create principal  (PrincipalAddRequest)
          PUT  /api/kerberos/principal       - modify principal  (ModifyPrincipalRequest)
    Requires: Windows, PowerShell 5.1+, ksetup.exe (built-in on modern Windows).
    Must be run as Administrator.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
#  CONFIGURATION
# =============================================================================

$ApiBase       = 'https://md.beta/api'   # MultiDirectory API root (no trailing slash)
$TlsSkipVerify = $true                   # Set $false when using a trusted CA

if ($TlsSkipVerify) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
        Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
'@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12 -bor
        [System.Net.SecurityProtocolType]::Tls13
}

# =============================================================================
#  HELPERS - UI
# =============================================================================

function Write-Header {
    param([string]$Text)
    $line = '-' * 62
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$line" -ForegroundColor Cyan
}

function Ask-YesNo {
    param([string]$Prompt)
    do { $a = (Read-Host "$Prompt [y/n]").Trim().ToLower() }
    while ($a -notin 'y','n','yes','no')
    return ($a -in 'y','yes')
}

function Read-NonEmpty {
    param([string]$Prompt)
    do { $v = (Read-Host $Prompt).Trim() }
    while ([string]::IsNullOrWhiteSpace($v))
    return $v
}

# =============================================================================
#  HELPERS - PASSWORD GENERATION
# =============================================================================

function New-StrongPassword {
    <#
    Cryptographically random password, 12-32 characters.
    Guaranteed: >=2 uppercase, >=2 lowercase, >=2 digits, >=2 symbols.
    #>
    $rng    = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $length = Get-Random -Minimum 12 -Maximum 33   # 12..32 inclusive

    $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $lower   = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $digits  = '0123456789'.ToCharArray()
    $symbols = '!@#$%^&*()-_=+[]{}|;:,.<>?'.ToCharArray()
    $all     = $upper + $lower + $digits + $symbols

    # Mandatory characters (complexity guarantee)
    $mandatory = @(
        ($upper   | Get-Random -Count 2)
        ($lower   | Get-Random -Count 2)
        ($digits  | Get-Random -Count 2)
        ($symbols | Get-Random -Count 2)
    )

    # Fill the rest with RNG-selected characters from the full set
    $buf = New-Object byte[] ($length - $mandatory.Count)
    $rng.GetBytes($buf)
    $extra = $buf | ForEach-Object { $all[$_ % $all.Length] }

    # Shuffle via RNG-keyed sort
    $combined = ($mandatory + $extra) | ForEach-Object {
        $b = New-Object byte[] 4; $rng.GetBytes($b)
        [PSCustomObject]@{ C = $_; R = [System.BitConverter]::ToUInt32($b, 0) }
    } | Sort-Object R | Select-Object -ExpandProperty C

    return ($combined -join '')
}

# =============================================================================
#  HELPERS - MULTIDIRECTORY API  (v2.8.0e-01)
# =============================================================================

# Shared cookie session - populated by Invoke-ApiLogin, reused by all calls
$script:WebSession = $null

function Invoke-ApiLogin {
    <#
    POST /api/auth/
    Content-Type: application/x-www-form-urlencoded
    Body fields:  username  (DN | userPrincipalName | sAMAccountName)
                  password

    The server returns an HTTP-only cookie that authenticates subsequent
    requests.  Captured in $script:WebSession via -SessionVariable.
    Response body is null on plain success, or MFAChallengeResponse if MFA
    is configured.
    #>
    param(
        [string]$Username,
        [string]$Password
    )

    $uri  = "$ApiBase/auth/"
    $body = "username=$([Uri]::EscapeDataString($Username))" +
            "&password=$([Uri]::EscapeDataString($Password))"

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $body `
            -SessionVariable 'script:WebSession'

        if ($resp -and $resp.PSObject.Properties['mfa_challenge']) {
            Write-Warning '  MFA challenge received. This script does not support MFA.'
            Write-Warning '  Disable MFA for this account or complete MFA manually, then re-run.'
            exit 1
        }
        Write-Host '  [OK] Authenticated to MultiDirectory API.' -ForegroundColor Green
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        throw "API login failed (HTTP $code): $_"
    }
}

function Invoke-ApiLogout {
    <# DELETE /api/auth/  - invalidates the server session. #>
    try {
        Invoke-RestMethod -Method Delete -Uri "$ApiBase/auth/" `
            -WebSession $script:WebSession | Out-Null
    }
    catch { <# silently ignore logout errors #> }
}

function New-KerberosPrincipal {
    <#
    POST /api/kerberos/principal
    Body (PrincipalAddRequest):
      {
        "principal_name": "host/<fqdn>@<REALM>",
        "algorithms":     ["aes256-cts-hmac-sha1-96","aes128-cts-hmac-sha1-96"],
        "password":       "<generated-password>"
      }

    HTTP 400 = principal already exists ->
      PUT /api/kerberos/principal  (ModifyPrincipalRequest) resets password+algorithms.
    #>
    param(
        [string]$ComputerName,
        [string]$Realm,
        [string]$Password
    )

    $fqdn      = "$($ComputerName.ToLower()).$($Realm.ToLower())"
    $principal = "host/$fqdn@$Realm"

    $body = @{
        principal_name = $principal
        algorithms     = @('aes256-cts-hmac-sha1-96', 'aes128-cts-hmac-sha1-96')
        password       = $Password
    } | ConvertTo-Json -Compress

    Write-Host "  Principal : $principal"
    Write-Host "  Enctypes  : aes256-cts-hmac-sha1-96, aes128-cts-hmac-sha1-96"

    try {
        Invoke-RestMethod -Method Post -Uri "$ApiBase/kerberos/principal" `
            -ContentType 'application/json' `
            -Body $body `
            -WebSession $script:WebSession | Out-Null
        Write-Host '  [OK] Principal created.' -ForegroundColor Green
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -in 400, 409) {
            Write-Host '  [!] Principal already exists - resetting password & algorithms.' `
                -ForegroundColor Yellow
            $modBody = @{
                principal_name = $principal
                algorithms     = @('aes256-cts-hmac-sha1-96', 'aes128-cts-hmac-sha1-96')
                password       = $Password
            } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Method Put -Uri "$ApiBase/kerberos/principal" `
                    -ContentType 'application/json' `
                    -Body $modBody `
                    -WebSession $script:WebSession | Out-Null
                Write-Host '  [OK] Principal updated.' -ForegroundColor Green
            }
            catch { throw "Failed to update existing principal (HTTP $($_.Exception.Response.StatusCode.value__)): $_" }
        }
        else { throw "Failed to create principal (HTTP $code): $_" }
    }
}

# =============================================================================
#  HELPERS - DNS
# =============================================================================

function Resolve-KDC {
    <#
    Queries _kerberos._tcp.<REALM> SRV records.
    Returns an array of KDC hostnames sorted by SRV priority (lowest = highest priority).
    #>
    param([string]$Realm)
    $srv = "_kerberos._tcp.$Realm"
    Write-Host "  DNS SRV query: $srv" -ForegroundColor Gray
    try {
        $records = Resolve-DnsName -Name $srv -Type SRV -ErrorAction Stop
        $kdcs    = $records |
            Where-Object { $_.Type -eq 'SRV' } |
            Sort-Object Priority |
            Select-Object -ExpandProperty NameTarget
        if (-not $kdcs) { throw 'No SRV records returned.' }
        return @($kdcs)
    }
    catch { throw "DNS SRV lookup failed for '$srv': $_" }
}

function Set-DnsSuffixSearchOrder {
    <#
    Builds the search list:  <realm>  then  <parent domain>
    Example:  BD.BETA  ->  bd.beta, beta

    Applied to every active physical adapter and to the global registry key.
    #>
    param([string]$Realm)

    $realm  = $Realm.ToLower()
    $parts  = $realm -split '\.'
    $parent = if ($parts.Count -ge 2) { ($parts[1..($parts.Count-1)]) -join '.' } else { '' }

    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add($realm)
    if ($parent -and $parent -ne $realm) { $list.Add($parent) }

    # Per-adapter settings
    $adapters = Get-NetAdapter |
        Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -notmatch 'Loopback' }

    foreach ($adapter in $adapters) {
        try {
            $ipcfg = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
                         -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if (-not $ipcfg -or $ipcfg.ServerAddresses.Count -eq 0) { continue }
            Set-DnsClient -InterfaceIndex $adapter.ifIndex `
                -ConnectionSpecificSuffix $realm `
                -UseSuffixWhenRegistering $true
            Write-Host "  [OK] Adapter '$($adapter.Name)' -> suffix '$realm'" -ForegroundColor Green
        }
        catch { Write-Warning "  Adapter '$($adapter.Name)': $_" }
    }

    # Global registry key (survives adapter changes and reboots)
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $listStr = $list -join ','
    Set-ItemProperty -Path $regPath -Name 'SearchList' -Value $listStr -Type String
    Write-Host "  [OK] Global DNS SearchList -> $listStr" -ForegroundColor Green
}

# =============================================================================
#  PART A - COMPUTER NAME
# =============================================================================

Write-Header 'A  Computer Name'

$currentName  = $env:COMPUTERNAME
$renameNeeded = $false
$newName      = $null

Write-Host "  Current computer name: " -NoNewline
Write-Host $currentName -ForegroundColor Yellow

if (Ask-YesNo '  Do you want to change the computer name?') {
    $newName = Read-NonEmpty '  Enter new computer name'

    # NetBIOS name rules: 1-15 chars, alphanumeric + hyphen, no leading/trailing hyphen
    if ($newName -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-]{0,13}[A-Za-z0-9])?$') {
        Write-Warning "  '$newName' may violate NetBIOS naming rules (1-15 chars, alphanumeric/hyphen, no leading/trailing hyphen)."
        if (-not (Ask-YesNo '  Continue anyway?')) { $newName = $null }
    }

    if ($newName) {
        try {
            Rename-Computer -NewName $newName -Force
            Write-Host "  [OK] Rename to '$newName' scheduled. Takes effect after reboot." `
                -ForegroundColor Green
            $renameNeeded = $true
        }
        catch { Write-Warning "  Rename failed: $_" }
    }
}

# Use the pending name when registering the principal so it matches post-reboot
$effectiveName = if ($renameNeeded -and $newName) { $newName } else { $currentName }

# =============================================================================
#  PART B - KERBEROS REALM JOIN
# =============================================================================

Write-Header 'B  Kerberos Realm Join'

$realmJoinDone = $false

if (Ask-YesNo '  Do you want to join a Kerberos realm?') {

    # -- Step 1: Realm name + credentials -------------------------------------

    Write-Header '  Step 1  Realm & credentials'

    $realm      = (Read-NonEmpty '  Realm name (e.g. BD.BETA)').ToUpper()
    $adminUser  = Read-NonEmpty  "  Admin username for $realm (UPN / sAMAccountName / DN)"
    $adminPassS = Read-Host      "  Admin password for $realm" -AsSecureString
    $adminPass  = [System.Net.NetworkCredential]::new('', $adminPassS).Password

    # -- Step 2: DNS discovery + API login ------------------------------------

    Write-Header "  Step 2  Discover KDC + authenticate"

    $kdcs = @()
    try {
        $kdcs = Resolve-KDC -Realm $realm
        Write-Host "  KDC(s) found: $($kdcs -join ', ')" -ForegroundColor Green
    }
    catch {
        Write-Warning "  $_"
        Write-Host '  Continuing without verified KDC.' -ForegroundColor Yellow
    }

    Write-Host '  Logging in to MultiDirectory API...'
    try   { Invoke-ApiLogin -Username $adminUser -Password $adminPass }
    catch { Write-Error "$_"; exit 1 }

    # -- Step 3: Generate password + create principal -------------------------

    Write-Header '  Step 3  Create Kerberos principal'

    $compPassword = New-StrongPassword
    Write-Host ''
    Write-Host '  Generated computer password (copy before continuing):' -ForegroundColor Gray
    Write-Host "  $compPassword" -ForegroundColor Yellow
    Write-Host ''

    try   { New-KerberosPrincipal -ComputerName $effectiveName -Realm $realm -Password $compPassword }
    catch { Write-Error "$_"; Invoke-ApiLogout; exit 1 }

    Invoke-ApiLogout

    # -- Step 4: ksetup /setcomputerpassword ----------------------------------

    Write-Header '  Step 4  ksetup /setcomputerpassword'

    try {
        $proc = Start-Process ksetup.exe `
            -ArgumentList "/setcomputerpassword `"$compPassword`"" `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { throw "Exit code $($proc.ExitCode)" }
        Write-Host '  [OK] Computer password set.' -ForegroundColor Green
    }
    catch { Write-Warning "  ksetup /setcomputerpassword failed: $_" }

    # -- Step 5: ksetup realm configuration -----------------------------------

    Write-Header "  Step 5  ksetup realm configuration"

    foreach ($kdc in $kdcs) {
        $out = & ksetup.exe /addkdc $realm $kdc 2>&1
        $col = if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Yellow' }
        Write-Host "  ksetup /addkdc $realm $kdc -> $out" -ForegroundColor $col
    }

    try {
        $proc2 = Start-Process ksetup.exe `
            -ArgumentList "/setrealm `"$realm`"" `
            -Wait -PassThru -NoNewWindow
        if ($proc2.ExitCode -ne 0) { throw "Exit code $($proc2.ExitCode)" }
        Write-Host "  [OK] Realm set to '$realm'." -ForegroundColor Green
    }
    catch { Write-Warning "  ksetup /setrealm failed: $_" }

    # Map all local accounts to the realm (convenience; optional)
    & ksetup.exe /mapuser * * 2>&1 | Out-Null

    # -- Step 6: DNS suffix search order --------------------------------------

    Write-Header '  Step 6  DNS suffix search order'

    try   { Set-DnsSuffixSearchOrder -Realm $realm }
    catch { Write-Warning "  DNS suffix update failed: $_" }

    $realmJoinDone = $true
}
else {
    Write-Host '  Skipping realm join.' -ForegroundColor Yellow
    $realm = ''
    $kdcs  = @()
}

# =============================================================================
#  SUMMARY
# =============================================================================

Write-Header 'Summary'

Write-Host "  Computer name    : $effectiveName$(if($renameNeeded){' (rename pending reboot)'})"

if ($realmJoinDone) {
    $realmLower = $realm.ToLower()
    $parts      = $realmLower -split '\.'
    $parent     = if ($parts.Count -ge 2) { ($parts[1..($parts.Count-1)]) -join '.' } else { $realmLower }

    Write-Host "  Realm            : $realm"
    Write-Host "  KDC(s)           : $(if($kdcs){$kdcs -join ', '}else{'(not resolved via DNS)'})"
    Write-Host "  Principal        : host/$($effectiveName.ToLower()).$realmLower@$realm"
    Write-Host "  Enctypes         : aes256-cts-hmac-sha1-96, aes128-cts-hmac-sha1-96"
    Write-Host "  DNS search list  : $realmLower$(if($parent -and $parent -ne $realmLower){", $parent"})"
}

# =============================================================================
#  REBOOT
# =============================================================================

Write-Header 'Reboot'

if ($renameNeeded) {
    Write-Host '  [!] A reboot is REQUIRED for the computer rename to take effect.' `
        -ForegroundColor Magenta
}

Write-Host ''
Write-Host '  A reboot is strongly recommended so that:' -ForegroundColor White
if ($renameNeeded) {
    Write-Host '    * The new computer name is applied system-wide.'
}
if ($realmJoinDone) {
    Write-Host '    * Kerberos realm settings are fully loaded by the OS.'
    Write-Host '    * The new computer password and host principal become active.'
    Write-Host '    * The DNS suffix search order is applied to all services.'
}
Write-Host ''

if (Ask-YesNo '  Reboot now?') {
    Write-Host ''
    Write-Host '  Rebooting in 10 seconds. Press Ctrl+C to cancel.' -ForegroundColor Yellow
    for ($i = 10; $i -ge 1; $i--) {
        Write-Host "  $i..." -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    Restart-Computer -Force
}
else {
    Write-Host ''
    Write-Host '  Reboot skipped.' -ForegroundColor Yellow
    Write-Host '  Please reboot manually before using Kerberos authentication.' -ForegroundColor Yellow
    Write-Host ''
}
