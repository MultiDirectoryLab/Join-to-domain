#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Join Windows computer to Kerberos realm using LDAP API
.DESCRIPTION
    This script manages computer name, creates Kerberos principal, and configures DNS settings
#>

# Configuration
$API_BASE_URL = ""  # Will be set based on realm name
$script:NewComputerName = ""  # Will be set if computer name is changed

# Helper function to generate secure random password
function New-SecurePassword {
    param(
        [int]$MinLength = 12,
        [int]$MaxLength = 32
    )
    
    $length = Get-Random -Minimum $MinLength -Maximum ($MaxLength + 1)
    $chars = @()
    
    # Ensure password complexity
    $chars += [char](Get-Random -Minimum 65 -Maximum 91)    # Uppercase
    $chars += [char](Get-Random -Minimum 97 -Maximum 123)   # Lowercase
    $chars += [char](Get-Random -Minimum 48 -Maximum 58)    # Digit
    $chars += [char](Get-Random -Minimum 33 -Maximum 48)    # Special
    
    # Fill remaining characters
    $allChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+[]{}|;:,.<>?'
    for ($i = $chars.Count; $i -lt $length; $i++) {
        $chars += $allChars[(Get-Random -Minimum 0 -Maximum $allChars.Length)]
    }
    
    # Shuffle the password
    $password = -join ($chars | Get-Random -Count $chars.Count)
    return $password
}

# Function to display menu
function Show-Menu {
    Clear-Host
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   Kerberos Realm Join Tool" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Current Computer Name: $env:COMPUTERNAME" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Change computer name (Current: $env:COMPUTERNAME)" -ForegroundColor White
    Write-Host "2. Join to realm" -ForegroundColor White
    Write-Host "3. Reboot" -ForegroundColor White
    Write-Host "4. Exit" -ForegroundColor White
    Write-Host ""
}

# Function to change computer name
function Change-ComputerName {
    Write-Host "`n=== Change Computer Name ===" -ForegroundColor Cyan
    Write-Host "Current computer name: $env:COMPUTERNAME" -ForegroundColor Yellow
    
    $newComputerName = Read-Host "Enter new computer name"
    
    if ([string]::IsNullOrWhiteSpace($newComputerName)) {
        Write-Host "Invalid computer name. Operation cancelled." -ForegroundColor Red
        return
    }
    
    try {
        Rename-Computer -NewName $newComputerName -Force
        $script:NewComputerName = $newComputerName
        Write-Host "Computer name changed to: $newComputerName" -ForegroundColor Green
        Write-Host "NOTE: A reboot is required for the name change to take effect." -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to rename computer: $_"
    }
    
    Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
    Read-Host
}

# Function to join realm
function Join-KerberosRealm {
    Write-Host "`n=== Join Kerberos Realm ===" -ForegroundColor Cyan
    
    # Get realm name and credentials
    $realmNameInput = Read-Host "Enter realm name (e.g., EXAMPLE.COM)"
    if ([string]::IsNullOrWhiteSpace($realmNameInput)) {
        Write-Host "Invalid realm name. Operation cancelled." -ForegroundColor Red
        Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
        Read-Host
        return
    }
    
    # Normalize realm name to uppercase
    $realmName = $realmNameInput.ToUpper()
    Write-Host "Using realm: $realmName" -ForegroundColor Green
    
    $script:API_BASE_URL = "https://$realmName/api"
    $adminUsername = Read-Host "Enter admin username"
    $adminPassword = Read-Host "Enter admin password" -AsSecureString
    
    # Bypass SSL certificate validation for self-signed certificates
    Write-Host "`nConfiguring SSL certificate validation..." -ForegroundColor Yellow
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
        Write-Host "SSL certificate validation configured (accepting all certificates)" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not configure certificate policy: $_"
    }
    
    # Authenticate to API
    Write-Host "Authenticating to LDAP API..." -ForegroundColor Yellow
    try {
        # Convert SecureString to plain text for API call
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPassword)
        )
        
        # Prepare form data for authentication (application/x-www-form-urlencoded)
        # URL encode the values to handle special characters
        $encodedUsername = [Uri]::EscapeDataString($adminUsername)
        $encodedPassword = [Uri]::EscapeDataString($plainPassword)
        $authBody = "username=$encodedUsername&password=$encodedPassword"
        
        $authResponse = Invoke-RestMethod -Uri "$script:API_BASE_URL/auth/" -Method POST `
            -Body $authBody -ContentType "application/x-www-form-urlencoded" -SessionVariable session
        
        Write-Host "Authentication successful!" -ForegroundColor Green
    }
    catch {
        Write-Error "Authentication failed: $_"
        Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
        Read-Host
        return
    }
    
    # DNS Query for realm
    Write-Host "Querying DNS for realm: $realmName..." -ForegroundColor Yellow
    try {
        $kdcRecords = Resolve-DnsName -Name "_kerberos._tcp.$realmName" -Type SRV -ErrorAction SilentlyContinue
        if ($kdcRecords) {
            Write-Host "Found KDC servers:" -ForegroundColor Green
            $kdcRecords | ForEach-Object { Write-Host "  - $($_.NameTarget):$($_.Port)" }
        }
        else {
            Write-Warning "No KDC servers found via DNS. Continuing anyway..."
        }
    }
    catch {
        Write-Warning "DNS query failed: $_"
    }
    
    # Generate secure password for computer account
    # Use new computer name if it was changed, otherwise use current
    if (-not [string]::IsNullOrWhiteSpace($script:NewComputerName)) {
        $computerName = $script:NewComputerName
        Write-Host "Using NEW computer name: $computerName (will be active after reboot)" -ForegroundColor Yellow
    }
    else {
        $computerName = $env:COMPUTERNAME
        Write-Host "Using current computer name: $computerName" -ForegroundColor Yellow
    }
    Write-Host "Generating secure password for computer principal..." -ForegroundColor Yellow
    $computerPassword = New-SecurePassword -MinLength 20 -MaxLength 32
    Write-Host "Password generated (length: $($computerPassword.Length))" -ForegroundColor Green
    
    # Create Kerberos principal - using lowercase format: host/computername.realm
    $principalName = "host/$($computerName.ToLower()).$($realmName.ToLower())"
    Write-Host "Creating Kerberos principal: $principalName..." -ForegroundColor Yellow
    
    # Check if principal already exists by attempting to create it
    $principalExists = $false
    
    try {
        $principalBody = @{
            principal_name = $principalName
            algorithms = @("aes256-cts-hmac-sha1-96", "aes128-cts-hmac-sha1-96")
            password = $computerPassword
        }
        
        Write-Host "Sending request to: $script:API_BASE_URL/kerberos/principal" -ForegroundColor Gray
        Write-Host "Request body: $($principalBody | ConvertTo-Json -Compress)" -ForegroundColor Gray
        
        $principalResponse = Invoke-RestMethod -Uri "$script:API_BASE_URL/kerberos/principal" `
            -Method POST -Body ($principalBody | ConvertTo-Json) `
            -ContentType "application/json" -WebSession $session
        
        Write-Host "Kerberos principal created successfully!" -ForegroundColor Green
    }
    catch {
        $errorDetails = $_.ErrorDetails.Message
        
        # Check if error indicates principal already exists
        if ($errorDetails -match "already exist" -or $errorDetails -match "duplicate" -or $_.Exception.Response.StatusCode -eq 409) {
            $principalExists = $true
            Write-Warning "Principal $principalName already exists."
            
            $replace = Read-Host "Do you want to replace it? (y/n)"
            
            if ($replace -eq "y") {
                Write-Host "Deleting existing principal..." -ForegroundColor Yellow
                
                try {
                    # Delete existing principal
                    $deleteBody = @{
                        principal_name = $principalName
                    }
                    
                    $deleteResponse = Invoke-RestMethod -Uri "$script:API_BASE_URL/kerberos/principal/delete" `
                        -Method DELETE -Body ($deleteBody | ConvertTo-Json) `
                        -ContentType "application/json" -WebSession $session
                    
                    Write-Host "Existing principal deleted." -ForegroundColor Green
                    
                    # Create new principal
                    Write-Host "Creating new principal..." -ForegroundColor Yellow
                    $principalResponse = Invoke-RestMethod -Uri "$script:API_BASE_URL/kerberos/principal" `
                        -Method POST -Body ($principalBody | ConvertTo-Json) `
                        -ContentType "application/json" -WebSession $session
                    
                    Write-Host "Kerberos principal created successfully!" -ForegroundColor Green
                }
                catch {
                    Write-Error "Failed to replace principal: $_"
                    Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
                    Read-Host
                    return
                }
            }
            else {
                Write-Host "Principal replacement cancelled. Exiting realm join." -ForegroundColor Yellow
                Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
                Read-Host
                return
            }
        }
        else {
            Write-Error "Failed to create Kerberos principal: $errorDetails"
            Write-Host "`nPossible reasons:" -ForegroundColor Yellow
            Write-Host "  - Insufficient permissions" -ForegroundColor Gray
            Write-Host "  - Kerberos service not properly configured on server" -ForegroundColor Gray
            Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
            Read-Host
            return
        }
    }
    
    # Set computer password using ksetup
    Write-Host "Setting computer password with ksetup..." -ForegroundColor Yellow
    try {
        & ksetup /setcomputerpassword $computerPassword
        Write-Host "Computer password set successfully!" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to set computer password: $_"
    }
    
    # Set realm with ksetup
    Write-Host "Configuring realm with ksetup..." -ForegroundColor Yellow
    try {
        & ksetup /setrealm $realmName
        Write-Host "Realm configured successfully!" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to set realm: $_"
    }
    
    # Configure DNS settings
    Write-Host "Configuring DNS search order..." -ForegroundColor Yellow
    try {
        $networkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
        
        foreach ($adapter in $networkAdapters) {
            # Parse realm name for DNS suffixes
            # For BD.BETA: add bd.beta and beta
            $realmParts = $realmName.ToLower().Split('.')
            $dnsSuffixes = @()
            
            # Add full domain
            $dnsSuffixes += $realmName.ToLower()
            
            # Add parent domains
            for ($i = 1; $i -lt $realmParts.Count; $i++) {
                $parentDomain = $realmParts[$i..($realmParts.Count - 1)] -join '.'
                $dnsSuffixes += $parentDomain
            }
            
            Write-Host "  Setting DNS suffixes for adapter $($adapter.Name): $($dnsSuffixes -join ', ')" -ForegroundColor Gray
            
            # Set DNS suffix search list
            Set-DnsClientGlobalSetting -SuffixSearchList $dnsSuffixes
            
            # Get current DNS servers
            $currentDns = Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4
            Write-Host "  Current DNS servers: $($currentDns.ServerAddresses -join ', ')" -ForegroundColor Gray
        }
        
        Write-Host "DNS configuration completed!" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to configure DNS: $_"
    }
    
    # Display summary
    Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Computer Name: $computerName" -ForegroundColor White
    Write-Host "Kerberos Realm: $realmName" -ForegroundColor White
    Write-Host "Principal Name: $principalName" -ForegroundColor White
    Write-Host "Encryption Types: AES-256-SHA1, AES-128-SHA1" -ForegroundColor White
    Write-Host "`nNOTE: A reboot is required to complete the configuration." -ForegroundColor Yellow
    
    Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
    Read-Host
}

# Function to reboot
function Restart-System {
    Write-Host "`n=== Reboot System ===" -ForegroundColor Cyan
    $confirm = Read-Host "Are you sure you want to reboot now? (y/n)"
    
    if ($confirm -eq "y") {
        Write-Host "Rebooting in 10 seconds..." -ForegroundColor Yellow
        Write-Host "Press Ctrl+C to cancel" -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    }
    else {
        Write-Host "Reboot cancelled." -ForegroundColor Yellow
        Write-Host "`nPress Enter to continue..." -ForegroundColor Yellow
        Read-Host
    }
}

# Main loop
do {
    Show-Menu
    $choice = Read-Host "Select an option (1-4)"
    
    switch ($choice) {
        "1" { Change-ComputerName }
        "2" { Join-KerberosRealm }
        "3" { Restart-System }
        "4" { 
            Write-Host "`nExiting..." -ForegroundColor Green
            exit 0
        }
        default {
            Write-Host "`nInvalid choice. Please select 1-4." -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
} while ($true)