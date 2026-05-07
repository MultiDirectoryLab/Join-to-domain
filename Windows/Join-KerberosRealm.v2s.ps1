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
# SIG # Begin signature block
# MIIoOwYJKoZIhvcNAQcCoIIoLDCCKCgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUJo8nq4kYvUC5sna0EzhMH7to
# lLuggiFxMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
# AQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz
# 7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS
# 5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7
# bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfI
# SKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jH
# trHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14
# Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2
# h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt
# 6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPR
# iQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ER
# ElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4K
# Jpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAd
# BgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SS
# y4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAC
# hjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURS
# b290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRV
# HSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyh
# hyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO
# 0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo
# 8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++h
# UD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5x
# aiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGtDCCBJyg
# AwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQG
# EwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNl
# cnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjUw
# NTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQg
# VGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URedTa2N
# DZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW2qft
# JYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH++0t
# rj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7RdoX
# 0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBYqHEp
# NVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk81coW
# J+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqUJfdk
# DjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3hj0Xb
# Qcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW//1sf
# uZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyODi7v
# QTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIspzOwb
# tmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYE
# FO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/n
# upiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3Bggr
# BgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNv
# bTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2Ny
# bDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0g
# BBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQAX
# zvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXjDNJQ
# a8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoalhnd
# 6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQYK9FH
# aoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId+ZOc
# zgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQCqjFb
# qrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yosn0z
# 4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ1KYT
# 70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk43es
# aUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEdmcif
# /sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjlgp2+
# VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBuYwggTOoAMCAQICEHe9
# DgOhtwj4VKsGchDZBEcwDQYJKoZIhvcNAQELBQAwUzELMAkGA1UEBhMCQkUxGTAX
# BgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29k
# ZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAwMDAwMFoXDTMwMDcyODAwMDAw
# MFowWTELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExLzAt
# BgNVBAMTJkdsb2JhbFNpZ24gR0NDIFI0NSBDb2RlU2lnbmluZyBDQSAyMDIwMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA1kJN+eNPxiP0bB2BpjD3SD3P
# 0OWN5SAilgdENV0Gzw8dcGDmJlT6UyNgAqhfAgL3jsluPal4Bb2O9U8ZJJl8zxEW
# mx97a9Kje2hld6vYsSw/03IGMlxbrFBnLCVNVgY2/MFiTH19hhaVml1UulDQsH+i
# RBnp1m5sPhPCnxHUXzRbUWgxYwr4W9DeullfMa+JaDhAPgjoU2dOY7Yhju/djYVB
# VZ4cvDfclaDEcacfG6VJbgogWX6Jo1gVlwAlad/ewmpQZU5T+2uhnxgeig5fVF69
# 4FvP8gwE0t4IoRAm97Lzei7CjpbBP86l2vRZKIw3ZaExlguOpHZ3FUmEZoIl50MK
# d1KxmVFC/6Gy3ZzS3BjZwYapQB1Bl2KGvKj/osdjFwb9Zno2lAEgiXgfkPR7qVJO
# ak9UBiqAr57HUEL6ZQrjAfSxbqwOqOOBGag4yJ4DKIakdKdHlX5yWip7FWocxGnm
# sL5AGZnL0n1VTiKcEOChW8OzLnqLxN7xSx+MKHkwRX9sE7Y9LP8tSooq7CgPLcrU
# nJiKSm1aNiwv37rL4kFKCHcYiK01YZQS86Ry6+42nqdRJ5E896IazPyH5ZfhUYdp
# 6SLMg8C3D0VsB+FDT9SMSs7PY7G1pBB6+Q0MKLBrNP4haCdv7Pj6JoRbdULNiSZ5
# WZ1rq2NxYpAlDQgg8f8CAwEAAaOCAa4wggGqMA4GA1UdDwEB/wQEAwIBhjATBgNV
# HSUEDDAKBggrBgEFBQcDAzASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBTa
# s43AJJCja3fTDKBZ3SFnZHYLeDAfBgNVHSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQ
# u86WOzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3Nw
# Lmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6
# aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvY29kZXNpZ25pbmdy
# b290cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAyhjBodHRwOi8vY3JsLmdsb2JhbHNp
# Z24uY29tL2NvZGVzaWduaW5ncm9vdHI0NS5jcmwwVgYDVR0gBE8wTTBBBgkrBgEE
# AaAyATIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20v
# cmVwb3NpdG9yeS8wCAYGZ4EMAQQBMA0GCSqGSIb3DQEBCwUAA4ICAQAIiHImxq/6
# rF8GwKqMkNrQssCil/9uEzIWVP0+9DARn4+Y+ZtS3fKiFu7ZeJWmmnxhuAS1+OvL
# 9GERM/ZlJbcRQovYaW7H/5W0gUOpfq6/gtZNzBGjg3FqEF4ZBafnbH9W9Khcw04J
# rVlruPl+pS64/N4OwqD7sATUExvHJ6m5qi0xO89GTJ3rTOy8Lpzxh6N/OGlfQUBn
# 9lN96kHvjj37qdQROEbfPOv2zSK9E83w4eblM6C+POR41RvMIPIwc7AiHPaE1ptc
# AALhKFJL/xJLQOrusBoGBp6E5ufw24RG+3PZK0K2yVc0xxbApushuaoO9/7byuu8
# F8u4Z+vjPk/bqZSGZFXJCQrA2QRxShFLWmTDvHh4rUxHJmUHmdXNNmChM1Oz9nsq
# 1YlAPHGlq/iZWf3jm5JL3QW9Cwx4BivPU9i9EppbJ4aFP5G+4HiAc1Tfpx1nK2q2
# rk2JgCQIUnBQ8wH/RK4vmuDhSQjh4VvXONGeCoqdlCebyqO52+I2auNvuVhi4DZ4
# NgH6waeJeiZTo1y70rLristjCC/+HvNWKeI1m9j/6aW9bUtZLIksL1K7tSmQ2kNH
# vHLdvNm/gMHcsKu0Sx1YNjdk65vhhReaKaL95gjSkv+g+Hzh6afRMI5fJlArx6Li
# l3eK79hNPibrmUBg8zxnDLYIcik1U4E03DCCBu0wggTVoAMCAQICEAqA7xhLjfEF
# gtHEdqeVdGgwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoT
# DkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRp
# bWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0yNTA2MDQwMDAw
# MDBaFw0zNjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJTQTQwOTYgVGlt
# ZXN0YW1wIFJlc3BvbmRlciAyMDI1IDEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDQRqwtEsae0OquYFazK1e6b1H/hnAKAd/KN8wZQjBjMqiZ3xTWcfsL
# wOvRxUwXcGx8AUjni6bz52fGTfr6PHRNv6T7zsf1Y/E3IU8kgNkeECqVQ+3bzWYe
# sFtkepErvUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDMemQFoxQ2Dsw4vEjoT1FpS54d
# NApZfKY61HAldytxNM89PZXUP/5wWWURK+IfxiOg8W9lKMqzdIo7VA1R0V3Zp3Dj
# jANwqAf4lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7XOc4zyh1uSqgr6UnbksIcFJq
# LbkIXIPbcNmA98Oskkkrvt6lPAw/p4oDSRZreiwB7x9ykrjS6GS3NR39iTTFS+EN
# TqW8m6THuOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07hqF+8CTXaETkVWz0dVVZw7kn
# h1WZXOLHgDvundrAtuvz0D3T+dYaNcwafsVCGZKUhQPL1naFKBy1p6llN3QgshRt
# a6Eq4B40h5avMcpi54wm0i2ePZD5pPIssoszQyF4//3DoK2O65Uck5Wggn8O2klE
# TsJ7u8xEehGifgJYi+6I03UuT1j7FnrqVrOzaQoVJOeeStPeldYRNMmSF3voIgMF
# tNGh86w3ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNVwppwn4D3/Pt5pwIDAQABo4IB
# lTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU5Dv88jHt/f3X85FxYxlQQ89h
# jOgwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYDVR0PAQH/BAQD
# AgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcBAQSBiDCBhTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0GCCsGAQUFBzAC
# hlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRU
# aW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYDVR0fBFgwVjBU
# oFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0
# VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAGA1UdIAQZMBcw
# CAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAZSqt8Rwn
# BLmuYEHs0QhEnmNAciH45PYiT9s1i6UKtW+FERp8FgXRGQ/YAavXzWjZhY+hIfP2
# JkQ38U+wtJPBVBajYfrbIYG+Dui4I4PCvHpQuPqFgqp1PzC/ZRX4pvP/ciZmUnth
# fAEP1HShTrY+2DE5qjzvZs7JIIgt0GCFD9ktx0LxxtRQ7vllKluHWiKk6FxRPyUP
# xAAYH2Vy1lNM4kzekd8oEARzFAWgeW3az2xejEWLNN4eKGxDJ8WDl/FQUSntbjZ8
# 0FU3i54tpx5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8VMbtoRAmaaslNXdCG1+lqvP4
# FbrQ6IwSBXkZagHLhFU9HCrG/syTRLLhAezu/3Lr00GrJzPQFnCEH1Y58678Igmf
# ORBPC1JKkYaEt2OdDh4GmO0/5cHelAK2/gTlQJINqDr6JfwyYHXSd+V08X1JUPvB
# 4ILfJdmL+66Gp3CSBXG6IwXMZUXBhtCyIaehr0XkBoDIGMUG1dUtwq1qmcwbdUfc
# SYCn+OwncVUXf53VJUNOaMWMts0VlRYxe5nK+At+DI96HAlXHAL5SlfYxJ7La54i
# 71McVWRP66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4uPcU3AWVPGrbn5PhDBf3Frogu
# zzhk++ami+r3Qrx5bIbY3TVzgiFI7Gq3zWcwggdJMIIFMaADAgECAgw2vEC2AoNB
# HthaG3gwDQYJKoZIhvcNAQELBQAwWTELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExLzAtBgNVBAMTJkdsb2JhbFNpZ24gR0NDIFI0NSBDb2Rl
# U2lnbmluZyBDQSAyMDIwMB4XDTI2MDMxMjE0NDQwN1oXDTI3MDMxMzE0NDQwN1ow
# gZExCzAJBgNVBAYTAlJVMQ8wDQYDVQQIEwZNb3Njb3cxDzANBgNVBAcTBk1vc2Nv
# dzEUMBIGA1UEChMLTVVMVElGQUNUT1IxCzAJBgNVBAsTAklUMRQwEgYDVQQDEwtN
# VUxUSUZBQ1RPUjEnMCUGCSqGSIb3DQEJARYYdi5hYmxla292QG11bHRpZmFjdG9y
# LnJ1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA7XDoR0JYUwE8LwQE
# DEwTjwmJ9oef+zSGmP/xcgoD5VYKp0Gl3D2WJPgq6x0RZ8VonaEgGP6AN8rbYdYy
# teiehuab4mDdTEugH4JQdv+5VvfF3qJhKA/QIA39ZbM/0Ltii1LT2fnROwdbxp5R
# ICi1HaXC4HSQRSZubNsNsyK2fenkmtf6eBpjXuOv4Lg7TtZMAgwyT5lwLfsEUTbm
# NPRNXLc0KTlMJE/3A1VS7S266oWgYWAweFN4SU2jD1jrAwzD+KWtZPbmfhuXW4gn
# x+PBoymwurRRTyZwtvXpdhbktNcNPuIXDHTRNVM6C2yDQpgtKEcP3w1++2L7u9HE
# cwis/wm2wkCM0eJWpwgHSu1SuyJZ7VKyv8qBNpDQZCkzxWi4NUueTO/MYl3fDggT
# dIx5QKCMAxI3V8rZc+H90rLXjkxc1ygTTd0oNHk7rMcZK410SUz++HuaSt9NwqeK
# nYMIMPsA0e/Yy2c61vqRom+6DRwYu1Ncfm1xUDppzvvGxkBQzcE8KzrFYukNxCNl
# oB1hfLTKo/cO1dRu/2tvW9du5blEhMwn7LfaXUz3cWt8IKvh7iIY+OX4tDpp1Lsd
# yDw+fJwBM7UuVykTxW6QyjwgVi6jEWUi0H6ELnLs7DZy3SyF7J5aNauRBsXWoMWc
# mDfpxEWngGAF18yie+Egov0ZPcUCAwEAAaOCAdYwggHSMA4GA1UdDwEB/wQEAwIH
# gDCBmwYIKwYBBQUHAQEEgY4wgYswSgYIKwYBBQUHMAKGPmh0dHA6Ly9zZWN1cmUu
# Z2xvYmFsc2lnbi5jb20vY2FjZXJ0L2dzZ2NjcjQ1Y29kZXNpZ25jYTIwMjAuY3J0
# MD0GCCsGAQUFBzABhjFodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9nc2djY3I0
# NWNvZGVzaWduY2EyMDIwMFYGA1UdIARPME0wQQYJKwYBBAGgMgEyMDQwMgYIKwYB
# BQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAgG
# BmeBDAEEATAJBgNVHRMEAjAAMEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwu
# Z2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVjb2Rlc2lnbmNhMjAyMC5jcmwwIwYDVR0R
# BBwwGoEYdi5hYmxla292QG11bHRpZmFjdG9yLnJ1MBMGA1UdJQQMMAoGCCsGAQUF
# BwMDMB8GA1UdIwQYMBaAFNqzjcAkkKNrd9MMoFndIWdkdgt4MB0GA1UdDgQWBBRx
# WWvrTyaBDjxDXICVjFhv83XVEzANBgkqhkiG9w0BAQsFAAOCAgEAihSOC2E3/Nv8
# gmigGaizSqImTkesi2lwDuVk95ajRNk96vrAAiDCJJVJdXzIkf0/cz0gGz0sonLB
# g8iZvkSBdAW+7JSkJm53poqD1tBlzPenU5MFbf05+q3otnq/zxkqXxTTu70bazHG
# vu7SmK3X0HUZChfJraTx9aEOsPQefeKZhpUoB29BP4TsWt/SW7jswhhdbtZTsrkK
# FKkVR/sOG/xvSxnVODQBb64vkQlWoMZPRdMAKWnciJjWkSu8HqIfhi6RhAy4CfKW
# 2vC4gAWmeNczosFkfrF3hehbW4bCl+ni0ZsmfQhTHqLq77v8/j79EIm2bDTyqA86
# 7ZB/9v/vPDPPZjXJNN4MfJ75LqBa1B0cbmvVqvEcIkn55zAtPoC6FkFMcW6lUWog
# lzaKRC5ejv8lDWpf0yNgFpdfZSlsyT7OQoeDY+nhX6iOctsdsOFx2XuA8mxT1bwK
# PXF+xgN6zC3Bx78np+2z0nJybQRU+L6WH1ljB0cFW1K8R1EpyzHqwDN/04DlP9ky
# 5aOJGfTrKxAwnhlxe50mXBYh9Ay71HKHem4X++u0XT9AflosH1s279rqLQUbljUL
# jcopftBr0U9V6BLGex/WcW9lel2ZFgnyS/fPCgaD5hLd/u0c/U9ff9KkTz/30JWg
# 7S7mWb7h44Qr0Jesac7Afjzbne0q8iwxggY0MIIGMAIBATBpMFkxCzAJBgNVBAYT
# AkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMS8wLQYDVQQDEyZHbG9iYWxT
# aWduIEdDQyBSNDUgQ29kZVNpZ25pbmcgQ0EgMjAyMAIMNrxAtgKDQR7YWht4MAkG
# BSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMG
# CSqGSIb3DQEJBDEWBBRwbwJoRkEXad9j5S/nCCB/DcWIvTANBgkqhkiG9w0BAQEF
# AASCAgBBMeAAAuphNpWd7BNoZmTqWb9T2C9pRkUfOJ6q3ffMPy42cJVQYAGI1Oge
# YmQ2MhL6SdkaoKwUDiXTRCgnzolLDhvpdf84kRl4g4kocL0KChsoo6VZp/cYztN8
# SsBA0N3K4YD2cDmSJ4pqYK9ElyIb8wmGtEWdIl/gNqKJwimEo/nC0reOCgGhcjOV
# Qgv2kSzQyKNYnhAAxrxNTPDWyCp4bBQ1XpG0fbZVE6MABgVEHg1lTAP7M5QQq7YT
# +jGQz8L+7Fwvn4QI15noboIB+w5Hi9Z/sdyCXkcp3alznB0h17wiDAgLMMa5WXyX
# rLNOGugGvlHEi/h0xz8Giw2mgyYA7gXsrzBhoC/C5bb323mR86Yf4ayeFv5b4qda
# czy3mBxP7Uv7q34Rt2RI8phe+sBkG9mgWbVmR1OzXlWZIK/THmvZlvhA4N7bgjvn
# nCzgtWoqz9ypKRNYoEW++8BlKEb3GJQ0bEyqqcmXvHAClufAVctlUBUryTxJrEqh
# iXDTGVZuZEQvPXz+fXLa51JVSpDgF3A94f23Aar7STJVFwRFBxWASMbxq46VI/R9
# WlvTRB9dFpGRN6dSfag0RQ4kYWRF5/i8DjCR7L7ToRTHxBV3c84SHQXU2TOFzAir
# +1+rFlrYio5h8E8Il2TkMGP4xCuWXWLs9aWmqMOgQiPMX2ShBaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjExMjUxMTVaMC8GCSqGSIb3DQEJBDEiBCCMXSPh
# SLYa0Xgmprp3HuRohuWxrqlEgn3m/3Eqj01vSjANBgkqhkiG9w0BAQEFAASCAgCG
# /z3+1mMH4NUFoOqK8DsOg7VqBeC7QsdK3x3eqWaaOHMnoZrGVX6i52GY6j1Pi9h4
# NVRJJuzgPpry9qfF4JG00GI+Ohpc7aHtsI8uty5o3SJpPIjbOFt7joDfHQX9QRRl
# WtBufgS+jF2loS8gNru+Ut+odnaPZ82JHPHQbx0WjtexpnrtkBxCt4mikkpr3G9P
# TRszyMslDobtqb+dle4mGmPqhaUwZx/14iCc8Ec+W/kA27WZoMMRPwvGFAqQajkM
# 7W4DBaKxJrCrg8IEOKcCvkviYE9BeP6TWYbcTaV/jpuT3TDutqu6RgDSzwcUZ99x
# puGoVqe7BCuNXjpVTJKg1YPOSAF4b0vbWOsPcuGhLYVMkxoiiZzuzMP0jMlsAgsh
# fJ2tU3SeEJ/rHLWXWpqx9FNn8+9caQBzPRytK5LlObW5oVpaCph2MUs4KHstlV5E
# XCCnk6BG/hhDF0NAUsIunU9j2wbBUXBR9tbeuv/Beo4wJfqQ3ptX2vR5ItA3sdjW
# +PMENVEZolof9bjLDsZc9OWWBiuFJnSVtz3ehIpNyFwrg78wPK/iepWxm0f/QqFp
# LvofHSkAdOefT2mYJdUxHOezTV0kC1xMwKMb+zEKYHKOFOKWMyFH0HFloz2kkGNz
# 5fFfADT51IrLyvo4fqEoJZnXwEF3sHnaR0uKXLd7/Q==
# SIG # End signature block
