# UniFi Port Manager

PowerShell script to disable and re-enable ports on a UniFi managed switch via the local UCG Fiber controller API — while preserving all port configuration intact.

## Compatibility

Tested and confirmed working on:

| Component | Version |
|---|---|
| Controller hardware | UCG Fiber |
| UniFi OS firmware | 5.1.12 |
| UniFi Network application | bundled with OS 5.1.12 |
| Switch | USW Enterprise (USWED series) |
| PowerShell | 5.1 (Windows) and 7+ (Windows/macOS/Linux) |

The API layout used (`/api/auth/login`, `/proxy/network/api/s/{site}/...`) is the **UniFi OS** layout present on all UCG-series and UDM-series controllers. It will not work against a standalone UniFi Network Server (self-hosted) without adjusting the base paths.

## How It Works

### Authentication

The script authenticates against the local controller REST API — not Ubiquiti's cloud. No internet access is required.

1. `POST /api/auth/login` with `{username, password}` encoded as UTF-8 JSON bytes.
2. The controller returns a `TOKEN` cookie containing a signed JWT.
3. The CSRF token is extracted by base64-decoding the JWT payload and reading the `csrfToken` field.
4. Every subsequent API call carries the session cookie and `X-CSRF-Token` header.
5. `POST /api/auth/logout` closes the session when done.

The controller's self-signed TLS certificate is bypassed automatically (PS5 via a global policy override; PS7 via `-SkipCertificateCheck`).

### Disable flow

The UniFi API stores per-port customisations in a `port_overrides` array on each device object. The correct way to administratively disable a port is to set `"forward": "disabled"` in that port's override entry — **not** a boolean `disabled` field. The controller silently ignores unrecognised fields and will reject `forward: "disabled"` if conflicting fields are present, specifically:

- `native_networkconf_id` must be cleared to `""` (no VLAN assignment)
- `port_security_mac_address` must be cleared to `[]`
- `stp_edge_state` must be set to `"auto"`
- `stp_bpdu_guard_enabled` must be `false`

These constraints were discovered empirically by probing the live API — the controller returns `rc: ok` silently without applying the change when they are not met.

**Step by step:**

1. `GET /proxy/network/api/s/{site}/stat/device` — fetch all adopted devices, locate the target switch by name or MAC.
2. Read the current `port_overrides` entry for the target port and write it verbatim to `unifi_portN_state.json` (the snapshot).
3. Build a modified copy of the override with `forward: disabled` and the conflicting fields cleared.
4. `PUT /proxy/network/api/s/{site}/rest/device/{id}` — send the full `port_overrides` array with the modified entry.
5. Re-fetch the device and verify `forward == "disabled"` actually landed before reporting success.

### Enable flow

1. Read `unifi_portN_state.json`.
2. Restore the `original_override` from the snapshot exactly as it was — all fields, exact values including the original VLAN ID, port security MAC allowlist, STP settings, PoE mode, and port name.
3. `PUT` the restored array back to the controller.
4. On success, delete the snapshot file.

If the snapshot file is missing, the script falls back to setting `forward: "native"` on the current override while preserving all other fields.

### Snapshot file

```
unifi_port2_state.json   ← created on Disable, deleted on Enable
unifi_port5_state.json
```

Each file is self-contained: it records the controller URL, site, device MAC, port index, and the complete original `port_override` entry. Enable can be run from any machine that has the file.

> **Note:** Snapshot files contain network configuration details (VLAN IDs, internal device IDs). They are excluded from version control via `.gitignore` and should be treated as infrastructure config — keep them with your other network documentation, not in a public repo.

### Verification

After every Disable, the script re-fetches the device and checks that `forward == "disabled"` is present in the stored `port_overrides`. If the API accepted the request but the field did not land, the script removes the stale snapshot and exits with an error rather than reporting a false positive.

## Usage

```powershell
# List all adopted switches (find the right -DeviceName or -DeviceMac)
.\Manage-UniFiPort.ps1 -ListDevices

# Disable port 3 on a named switch
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3 -DeviceName "your-switch-name"

# Re-enable port 3 — restores exact original config from snapshot
.\Manage-UniFiPort.ps1 -Action Enable -PortNumber 3 -DeviceName "your-switch-name"

# Check current live state of port 3
.\Manage-UniFiPort.ps1 -Action Status -PortNumber 3 -DeviceName "your-switch-name"

# Target by MAC address instead of name
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3 -DeviceMac "aa:bb:cc:dd:ee:ff"

# Dry-run — authenticates and shows what would change, applies nothing
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3 -DeviceName "your-switch-name" -WhatIf

# Pass credentials inline (for Task Scheduler / automation)
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3 -DeviceName "your-switch-name" `
    -Username "svc_account" -Password "password"
```

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Action` | Yes* | — | `Disable`, `Enable`, or `Status` |
| `-PortNumber` | Yes* | — | Port index 1–16 |
| `-ListDevices` | — | — | Print all adopted switches and exit |
| `-DeviceName` | Yes† | — | Switch name as shown in the UniFi UI |
| `-DeviceMac` | Yes† | — | Switch MAC address (alternative to `-DeviceName`) |
| `-Username` | No | *(prompted)* | Controller admin username |
| `-Password` | No | *(prompted)* | Admin password |
| `-ControllerUrl` | No | `https://192.168.1.1` | Base URL of the UCG Fiber |
| `-Site` | No | `default` | UniFi site name |
| `-StateDir` | No | *(script folder)* | Directory for snapshot files |

\* Required when not using `-ListDevices`  
† One of `-DeviceName` or `-DeviceMac` is required for all actions

## Security Notes

- Credentials are never written to disk. The `-Password` parameter accepts plaintext for automation use; for interactive use the script prompts via `Get-Credential` (masked input).
- The controller's self-signed TLS certificate is bypassed — this is expected for local UniFi installations. Do not use this script against a controller exposed to the public internet without proper certificate handling.
- Snapshot files (`unifi_portN_state.json`) contain VLAN IDs, internal network object IDs, and port security MAC allowlists. They are excluded from git via `.gitignore`.
- The script uses a session cookie + CSRF token pattern — no API key or long-lived token is stored anywhere.
