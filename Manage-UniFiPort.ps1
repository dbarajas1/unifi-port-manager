#Requires -Version 5.1

<#
.SYNOPSIS
    Disable or enable a port on a UniFi USW Pro XG 8 PoE switch while preserving
    all port configuration (profile, VLAN, PoE mode, speed, STP settings, etc.).

.DESCRIPTION
    Authenticates to the UCG Fiber controller at 192.168.1.1 via the UniFi Network
    API (UniFi OS endpoint layout: /proxy/network/api/s/{site}/...).

    Disable:  snapshots the current port_override entry to a JSON sidecar file, then
              sets disabled=true on the port.  The switch brings the port down (no
              link, no PoE) while the controller retains every config detail.

    Enable:   reads the sidecar, restores the original override exactly (or removes
              the override entirely if no override existed before), then cleans up
              the snapshot file.

    Status:   shows the current live port-table entry and any stored override/snapshot.

    The script works for both Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Action
    Disable | Enable | Status

.PARAMETER PortNumber
    1-based port index.  Ports 1-8 are 10G copper; 9-10 are SFP28 uplinks on the
    USW Pro XG 8 PoE.

.PARAMETER Username
    UniFi controller admin username (default: admin).

.PARAMETER Password
    Admin password.  Prompted securely if omitted.

.PARAMETER ControllerUrl
    Base URL of the UCG Fiber (default: https://192.168.1.1).

.PARAMETER Site
    UniFi site name (default: default).

.PARAMETER DeviceMac
    Optional MAC address of the target switch (aa:bb:cc:dd:ee:ff).  Use when
    multiple USW Pro XG switches are adopted to the same controller.

.PARAMETER StateDir
    Directory where port-state snapshot files are written.
    Defaults to the same folder as this script.

.EXAMPLE
    # Disable port 3, prompting for password
    .\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3

    # Re-enable port 3 (restores exact original config)
    .\Manage-UniFiPort.ps1 -Action Enable -PortNumber 3

    # Check current state of port 5
    .\Manage-UniFiPort.ps1 -Action Status -PortNumber 5

    # Disable port 5 with password on command line, target specific switch
    .\Manage-UniFiPort.ps1 -Action Disable -PortNumber 5 -Password "S3cur3!" -DeviceMac "aa:bb:cc:11:22:33"

    # Preview what would change without applying (WhatIf)
    .\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateSet('Disable', 'Enable', 'Status')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateRange(1, 16)]
    [int]$PortNumber,

    [string]$Username,
    [string]$Password,
    [string]$ControllerUrl = 'https://192.168.1.1',
    [string]$Site          = 'default',
    [string]$DeviceMac,
    [string]$StateDir      = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── TLS / self-signed certificate bypass ─────────────────────────────────────
# UCG Fiber uses a self-signed certificate.  PS7+ handles this per-call via
# -SkipCertificateCheck; PS5 needs a global policy override.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class BypassAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                                      WebRequest req, int problem) { return true; }
}
'@   -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::CertificatePolicy  = [BypassAllCerts]::new()
    [System.Net.ServicePointManager]::SecurityProtocol   = [System.Net.SecurityProtocolType]::Tls12
}

# ─── Helper: extract csrfToken from UniFi OS JWT ──────────────────────────────
function Get-UniFiCsrfToken {
    param([Parameter(Mandatory)][string]$Jwt)
    # JWT = base64url(header).base64url(payload).signature
    $seg = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $seg += '=' * ((4 - $seg.Length % 4) % 4)
    $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg)) |
               ConvertFrom-Json
    if (-not $payload.csrfToken) { throw "csrfToken not found in JWT payload." }
    $payload.csrfToken
}

# ─── Helper: authenticated REST call ──────────────────────────────────────────
function Invoke-UniFiApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$CsrfToken,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [object]$Body
    )
    $p = @{
        Uri             = $Uri
        Method          = $Method
        WebSession      = $WebSession
        ContentType     = 'application/json'
        Headers         = @{ 'X-CSRF-Token' = $CsrfToken }
        UseBasicParsing = $true
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p['SkipCertificateCheck'] = $true }
    if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    Invoke-RestMethod @p
}

# ─── Helper: PSCustomObject → ordered hashtable (needed to mutate fields) ─────
function ConvertTo-Hashtable {
    param([Parameter(Mandatory)][psobject]$Obj)
    $ht = [ordered]@{}
    foreach ($prop in $Obj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
    $ht
}

# ─── State file for preserving config across Disable / Enable cycles ──────────
$stateFile = Join-Path $StateDir "unifi_port${PortNumber}_state.json"

# ══════════════════════════════════════════════════════════════════════════════
# 1. Prompt for credentials if omitted
# ══════════════════════════════════════════════════════════════════════════════
if (-not $Username) {
    $Username = (Read-Host "Username").Trim()
}
if (-not $Password) {
    $ss       = Read-Host "Password" -AsSecureString
    $Password = [System.Net.NetworkCredential]::new("", $ss).Password
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. Login — obtain session cookie + CSRF token
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[*] Authenticating to $ControllerUrl as '$Username' ..."
Write-Verbose "Credential check — username length: $($Username.Length)  password length: $($Password.Length)"

# Encode body as explicit UTF-8 bytes so Invoke-WebRequest cannot append
# "; charset=utf-16" to the Content-Type, which causes the UniFi API to
# misparse the JSON and reject otherwise-valid credentials.
$loginJson  = [ordered]@{ username = $Username; password = $Password } | ConvertTo-Json -Compress
$loginBytes = [System.Text.Encoding]::UTF8.GetBytes($loginJson)

$loginArgs = @{
    Uri             = "$ControllerUrl/api/auth/login"
    Method          = 'POST'
    Body            = $loginBytes
    ContentType     = 'application/json'
    Headers         = @{ Accept = 'application/json' }
    SessionVariable = 'webSession'
    UseBasicParsing = $true
}
if ($PSVersionTable.PSVersion.Major -ge 6) { $loginArgs['SkipCertificateCheck'] = $true }

try {
    Invoke-WebRequest @loginArgs | Out-Null
} catch {
    # Surface the raw API response body when available for easier diagnosis
    $detail = $_.ErrorDetails.Message
    if (-not $detail) { $detail = $_.Exception.Message }
    Write-Error "Login failed. Verify credentials and that $ControllerUrl is reachable.`nDetail: $detail"
    exit 1
}

# $webSession is now populated by -SessionVariable
$tokenCookie = $webSession.Cookies.GetCookies($ControllerUrl) |
               Where-Object { $_.Name -eq 'TOKEN' } |
               Select-Object -First 1

if (-not $tokenCookie) {
    Write-Error "TOKEN cookie not returned by controller.  Is this a UCG Fiber / UniFi OS device?"
    exit 1
}

try {
    $csrf = Get-UniFiCsrfToken -Jwt $tokenCookie.Value
} catch {
    Write-Error "Could not parse CSRF token from TOKEN cookie: $_"
    exit 1
}

Write-Host "[*] Authenticated — session and CSRF token acquired."

# ══════════════════════════════════════════════════════════════════════════════
# 3. Discover the USW Pro XG 8 PoE
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[*] Fetching adopted devices from site '$Site' ..."

$devResult  = Invoke-UniFiApi -Uri "$ControllerUrl/proxy/network/api/s/$Site/stat/device" `
                               -CsrfToken $csrf -WebSession $webSession
$allDevices = [array]@($devResult.data)

if (-not $allDevices -or $allDevices.Count -eq 0) {
    Write-Error "No devices returned.  Check the site name ('$Site') and that devices are adopted."
    exit 1
}

# Narrow to switches
$switches = [array]@($allDevices | Where-Object { $_.type -eq 'usw' })

# Apply optional MAC filter
if ($DeviceMac) {
    $normMac  = ($DeviceMac -replace '[:\-]', '').ToLower()
    $switches = [array]@($switches | Where-Object { ($_.mac -replace ':', '').ToLower() -eq $normMac })
}

# Prefer model-name match (USW-Pro-XG-8-PoE model codes seen in the wild)
$switch = $switches | Where-Object { $_.model -match 'USWXG|XG8P|XG-8|Pro-XG' } | Select-Object -First 1

# Fall back to any single remaining switch (useful in single-switch setups)
if (-not $switch -and $switches.Count -eq 1) {
    $switch = $switches[0]
}

if (-not $switch) {
    Write-Warning "Could not auto-detect USW Pro XG 8 PoE.  Adopted switches found:"
    if ($switches.Count -gt 0) {
        $switches | Sort-Object model | Format-Table mac, model, name -AutoSize
        Write-Error "Rerun with -DeviceMac to target the correct device."
    } else {
        Write-Error "No adopted switches found on site '$Site'."
    }
    exit 1
}

Write-Host "[*] Target device : $($switch.name)  model=$($switch.model)  mac=$($switch.mac)"
$deviceId = $switch._id

# ══════════════════════════════════════════════════════════════════════════════
# 4. Read current port_overrides for this port
# ══════════════════════════════════════════════════════════════════════════════
$currentOverrides = [array]@(if ($switch.port_overrides) { $switch.port_overrides } else { @() })
$portOverride     = $currentOverrides |
                    Where-Object { $_.port_idx -eq $PortNumber } |
                    Select-Object -First 1

# ══════════════════════════════════════════════════════════════════════════════
# ACTION: STATUS
# ══════════════════════════════════════════════════════════════════════════════
if ($Action -eq 'Status') {
    Write-Host "`n=== Port $PortNumber — controller override ==="
    if ($portOverride) {
        $portOverride | Format-List
    } else {
        Write-Host "(no override — port uses default profile)"
    }

    $livePort = $switch.port_table | Where-Object { $_.port_idx -eq $PortNumber }
    if ($livePort) {
        Write-Host "=== Port $PortNumber — live port-table ==="
        $livePort | Format-List
    }

    if (Test-Path $stateFile) {
        Write-Host "=== Snapshot on disk ($stateFile) ==="
        Get-Content $stateFile -Raw | ConvertFrom-Json | Format-List
    } else {
        Write-Host "(no snapshot file on disk)"
    }

    # Tidy logout and exit
    try { Invoke-UniFiApi -Uri "$ControllerUrl/api/auth/logout" -Method 'POST' `
                           -CsrfToken $csrf -WebSession $webSession | Out-Null } catch {}
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# ACTION: DISABLE
# ══════════════════════════════════════════════════════════════════════════════
if ($Action -eq 'Disable') {

    # Idempotency check
    if ($portOverride -and
        $portOverride.PSObject.Properties['disabled'] -and
        $portOverride.disabled -eq $true) {
        Write-Host "[!] Port $PortNumber is already disabled.  Nothing to do."
        try { Invoke-UniFiApi -Uri "$ControllerUrl/api/auth/logout" -Method 'POST' `
                               -CsrfToken $csrf -WebSession $webSession | Out-Null } catch {}
        exit 0
    }

    # Save snapshot: original override (or null if port had none)
    $snapshot = [ordered]@{
        captured_at       = (Get-Date -Format 'o')
        controller_url    = $ControllerUrl
        site              = $Site
        device_mac        = $switch.mac
        device_name       = $switch.name
        port_idx          = $PortNumber
        had_override      = ($null -ne $portOverride)
        original_override = $portOverride   # null is fine here
    }
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
    Write-Host "[*] Config snapshot saved → $stateFile"

    # Build the updated override: copy all existing fields then set disabled=true
    if ($portOverride) {
        $newOverride = ConvertTo-Hashtable $portOverride
    } else {
        $newOverride = [ordered]@{ port_idx = $PortNumber }
    }
    $newOverride['disabled'] = $true

    # Rebuild the full array (keep all other ports untouched)
    $otherOverrides = [array]@($currentOverrides | Where-Object { $_.port_idx -ne $PortNumber })
    $newOverrides   = if ($otherOverrides) { $otherOverrides + $newOverride } else { @($newOverride) }

    if ($PSCmdlet.ShouldProcess("Port $PortNumber on $($switch.name) [$($switch.mac)]", 'Disable port')) {
        $result = Invoke-UniFiApi `
            -Uri     "$ControllerUrl/proxy/network/api/s/$Site/rest/device/$deviceId" `
            -Method  'PUT' `
            -CsrfToken $csrf `
            -WebSession $webSession `
            -Body    @{ port_overrides = $newOverrides }

        if ($result.meta.rc -eq 'ok') {
            Write-Host "[+] Port $PortNumber DISABLED on $($switch.name)."
            Write-Host "    Run with -Action Enable -PortNumber $PortNumber to restore."
        } else {
            Write-Error "API returned non-ok status: $($result.meta | ConvertTo-Json -Depth 3)"
        }
    } else {
        Write-Host "[WhatIf] Would set port_overrides entry for port $PortNumber to: disabled=true"
        Write-Host "[WhatIf] (snapshot would be written to $stateFile)"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ACTION: ENABLE
# ══════════════════════════════════════════════════════════════════════════════
elseif ($Action -eq 'Enable') {

    if (Test-Path $stateFile) {
        # ── Restore from snapshot ─────────────────────────────────────────────
        $snapshot = Get-Content $stateFile -Raw | ConvertFrom-Json
        Write-Host "[*] Restoring config from snapshot captured $($snapshot.captured_at) ..."

        if ($snapshot.had_override -and $snapshot.original_override) {
            # Fully restore the original override (all fields, exact values)
            $restoredOverride = ConvertTo-Hashtable $snapshot.original_override
            $otherOverrides   = [array]@($currentOverrides | Where-Object { $_.port_idx -ne $PortNumber })
            $newOverrides     = if ($otherOverrides) { $otherOverrides + $restoredOverride }
                                else { @($restoredOverride) }
            Write-Host "[*] Restoring original port_override for port $PortNumber ..."
        } else {
            # Port had no override before — remove the disable-only entry entirely
            $otherOverrides = [array]@($currentOverrides | Where-Object { $_.port_idx -ne $PortNumber })
            $newOverrides   = if ($otherOverrides) { $otherOverrides } else { @() }
            Write-Host "[*] Port had no prior override — removing the disabled entry entirely ..."
        }

    } else {
        # ── No snapshot: best-effort enable by dropping the disabled flag ─────
        Write-Warning "Snapshot file not found at $stateFile."
        Write-Host "    Best-effort enable: removing 'disabled' flag from current override."

        if (-not $portOverride) {
            Write-Host "[!] Port $PortNumber has no override entry — it is not disabled.  Nothing to do."
            try { Invoke-UniFiApi -Uri "$ControllerUrl/api/auth/logout" -Method 'POST' `
                                   -CsrfToken $csrf -WebSession $webSession | Out-Null } catch {}
            exit 0
        }

        $restored = ConvertTo-Hashtable $portOverride
        $restored.Remove('disabled')
        $otherOverrides = [array]@($currentOverrides | Where-Object { $_.port_idx -ne $PortNumber })
        $newOverrides   = if ($otherOverrides) { $otherOverrides + $restored } else { @($restored) }
    }

    if ($PSCmdlet.ShouldProcess("Port $PortNumber on $($switch.name) [$($switch.mac)]", 'Enable port (restore config)')) {
        $result = Invoke-UniFiApi `
            -Uri     "$ControllerUrl/proxy/network/api/s/$Site/rest/device/$deviceId" `
            -Method  'PUT' `
            -CsrfToken $csrf `
            -WebSession $webSession `
            -Body    @{ port_overrides = $newOverrides }

        if ($result.meta.rc -eq 'ok') {
            Write-Host "[+] Port $PortNumber ENABLED on $($switch.name) — configuration fully restored."
            if (Test-Path $stateFile) {
                Remove-Item $stateFile -ErrorAction SilentlyContinue
                Write-Host "[*] Snapshot file removed."
            }
        } else {
            Write-Error "API returned non-ok status: $($result.meta | ConvertTo-Json -Depth 3)"
        }
    } else {
        Write-Host "[WhatIf] Would restore port $PortNumber override and remove $stateFile"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. Logout (non-fatal)
# ══════════════════════════════════════════════════════════════════════════════
try {
    Invoke-UniFiApi -Uri "$ControllerUrl/api/auth/logout" -Method 'POST' `
                    -CsrfToken $csrf -WebSession $webSession | Out-Null
    Write-Host "[*] Session closed."
} catch {
    # Session will expire on its own; not worth failing the script over
}
