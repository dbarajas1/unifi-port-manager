#Requires -Version 5.1
<#
.SYNOPSIS
    First-time setup wizard: writes port-config.json and saves the controller
    password to the macOS Keychain (or an encrypted file on Windows).

.DESCRIPTION
    Run once before using Set-SwitchPort.ps1 so that daily operations only need
    -Action and -PortNumber with no credentials on the command line.

    Password storage by platform:
      macOS  (PS7+)  — login Keychain via the 'security' command.
      Windows        — DPAPI-encrypted .unifi_pass file in the script folder.
      Linux / other  — not stored; set UNIFI_PASSWORD env var at run time.

.EXAMPLE
    .\Setup-Config.ps1
#>
param()

Set-StrictMode -Off

$configFile = Join-Path $PSScriptRoot 'port-config.json'

Write-Host ""
Write-Host "=== UniFi Port Manager — Setup Wizard ==="
Write-Host ""

# Load existing values as defaults
$existing = $null
if (Test-Path $configFile) {
    $existing = Get-Content $configFile -Raw | ConvertFrom-Json
}

function Read-HostDefault {
    param([string]$Prompt, [string]$Default)
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $val   = (Read-Host $label).Trim()
    if ($val) { $val } else { $Default }
}

$controllerUrl = Read-HostDefault 'Controller URL' (if ($existing) { $existing.controllerUrl } else { 'https://192.168.1.1' })
$site          = Read-HostDefault 'Site name'      (if ($existing) { $existing.site         } else { 'default'             })
$username      = Read-HostDefault 'Admin username'  (if ($existing) { $existing.username     } else { 'admin'               })
$deviceName    = Read-HostDefault 'Switch name (run Manage-UniFiPort.ps1 -ListDevices to find it)' `
                                  (if ($existing) { $existing.deviceName } else { '' })
$apiPortStr    = Read-HostDefault 'API server port (port-api.js)' `
                                  (if ($existing -and $existing.apiPort) { $existing.apiPort.ToString() } else { '8765' })

# Secure credential prompt
Write-Host ""
$cred = if ($username) {
    Get-Credential -UserName $username -Message "Enter password for '$username' at $controllerUrl"
} else {
    Get-Credential -Message "Enter password for $controllerUrl"
}
if (-not $cred) { Write-Error "No credentials provided."; exit 1 }
$username = $cred.UserName.Trim()
$password = $cred.GetNetworkCredential().Password

# Generate or reuse API token (used by port-api.js for remote auth)
$existingToken = if ($existing -and
                     $existing.apiToken -and
                     $existing.apiToken -ne 'REPLACE_WITH_A_LONG_RANDOM_SECRET') {
    $existing.apiToken
} else { $null }

$apiToken = if ($existingToken) {
    $existingToken
} else {
    $bytes = [byte[]]::new(36)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes)
}

# Write config file — password is NOT stored here
$config = [ordered]@{
    controllerUrl = $controllerUrl
    site          = $site
    username      = $username
    deviceName    = $deviceName
    apiPort       = [int]$apiPortStr
    apiToken      = $apiToken
}
$config | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
Write-Host ""
Write-Host "[+] Config saved  → $configFile"

# Store password based on platform
$controllerHost  = ([System.Uri]$controllerUrl).Host
$keychainService = "unifi-port-manager-$controllerHost"
$isMacOS         = ($PSVersionTable.PSVersion.Major -ge 6) -and $IsMacOS

if ($isMacOS) {
    security delete-generic-password -s $keychainService -a $username 2>$null
    security add-generic-password    -s $keychainService -a $username -w $password
    Write-Host "[+] Password saved → macOS Keychain (service: $keychainService)"
} else {
    $passFile  = Join-Path $PSScriptRoot '.unifi_pass'
    $secureStr = ConvertTo-SecureString $password -AsPlainText -Force
    try {
        $secureStr | ConvertFrom-SecureString | Set-Content $passFile -Encoding UTF8
        Write-Host "[+] Password saved → $passFile (DPAPI-encrypted)"
    } catch {
        Write-Warning "DPAPI encryption not available on this platform."
        Write-Warning "Set the UNIFI_PASSWORD environment variable before running Set-SwitchPort.ps1."
    }
}

Write-Host ""
Write-Host "=== Setup complete ==="
Write-Host ""
Write-Host "  Disable a port:   .\Set-SwitchPort.ps1 -Action Disable -PortNumber 3"
Write-Host "  Enable a port:    .\Set-SwitchPort.ps1 -Action Enable  -PortNumber 3"
Write-Host "  Check port state: .\Set-SwitchPort.ps1 -Action Status  -PortNumber 3"
Write-Host ""
Write-Host "  Remote API:       node port-api.js   (keep terminal open)"
Write-Host ""
Write-Host "  API token for remote access:"
Write-Host "  $apiToken"
Write-Host ""
