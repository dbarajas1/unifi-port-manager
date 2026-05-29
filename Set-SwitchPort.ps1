#Requires -Version 5.1
<#
.SYNOPSIS
    Thin wrapper around Manage-UniFiPort.ps1 that reads port-config.json so
    daily use only needs -Action and -PortNumber.

.DESCRIPTION
    Run Setup-Config.ps1 once to create port-config.json and save the password.
    After that, this script handles credential lookup automatically:

      1. UNIFI_PASSWORD environment variable (highest priority)
      2. macOS Keychain  (macOS + PS7)
      3. DPAPI-encrypted .unifi_pass file  (Windows)
      4. Get-Credential prompt  (fallback)

.EXAMPLE
    .\Set-SwitchPort.ps1 -Action Disable -PortNumber 3
    .\Set-SwitchPort.ps1 -Action Enable  -PortNumber 3
    .\Set-SwitchPort.ps1 -Action Status  -PortNumber 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Disable', 'Enable', 'Status')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateRange(1, 16)]
    [int]$PortNumber
)

$configFile = Join-Path $PSScriptRoot 'port-config.json'
if (-not (Test-Path $configFile)) {
    Write-Error "port-config.json not found.  Run .\Setup-Config.ps1 first."
    exit 1
}

$cfg = Get-Content $configFile -Raw | ConvertFrom-Json

if (-not $cfg.deviceName) {
    Write-Error "deviceName is not set in port-config.json.  Run .\Setup-Config.ps1 and specify the switch name."
    exit 1
}

# Password resolution order: env var → Keychain (macOS) → encrypted file → prompt
$password = $env:UNIFI_PASSWORD

if (-not $password) {
    $isMacOS = ($PSVersionTable.PSVersion.Major -ge 6) -and $IsMacOS
    if ($isMacOS) {
        $controllerHost  = ([System.Uri]$cfg.controllerUrl).Host
        $keychainService = "unifi-port-manager-$controllerHost"
        try {
            $password = (security find-generic-password -s $keychainService -a $cfg.username -w 2>$null)
        } catch {}
    } else {
        $passFile = Join-Path $PSScriptRoot '.unifi_pass'
        if (Test-Path $passFile) {
            try {
                $enc       = Get-Content $passFile -Raw -ErrorAction Stop
                $secureStr = $enc.Trim() | ConvertTo-SecureString -ErrorAction Stop
                $password  = [System.Net.NetworkCredential]::new('', $secureStr).Password
            } catch {}
        }
    }
}

if (-not $password) {
    $cred = if ($cfg.username) {
        Get-Credential -UserName $cfg.username -Message "Enter password for $($cfg.controllerUrl)"
    } else {
        Get-Credential -Message "Enter password for $($cfg.controllerUrl)"
    }
    if (-not $cred) { Write-Error "No credentials provided."; exit 1 }
    $password = $cred.GetNetworkCredential().Password
}

$scriptParams = @{
    Action        = $Action
    PortNumber    = $PortNumber
    Username      = $cfg.username
    Password      = $password
    ControllerUrl = $cfg.controllerUrl
    Site          = $cfg.site
    DeviceName    = $cfg.deviceName
}

& (Join-Path $PSScriptRoot 'Manage-UniFiPort.ps1') @scriptParams
