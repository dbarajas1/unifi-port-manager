# UniFi Port Manager

PowerShell script to disable and re-enable ports on a UniFi USW Pro XG 8 PoE switch managed by a UCG Fiber controller — while preserving all port configuration intact.

## Overview

`Manage-UniFiPort.ps1` uses the local UniFi Network API to administratively shut down a switch port (no link, no PoE) and bring it back up with every setting fully restored: port profile, VLAN, PoE mode, speed, STP, and any other overrides.

A JSON snapshot file (`unifi_portN_state.json`) is written before each disable operation and consumed on re-enable, guaranteeing exact config restoration even across reboots or days between operations.

## Environment

| Component | Detail |
|---|---|
| Controller | UCG Fiber (`SJ-FW-01`) at `192.168.1.1` |
| Firmware | 5.1.12 (UniFi OS) |
| Switch | USW Pro XG 8 PoE |
| Ports | 1–8 copper 10G, 9–10 SFP28 uplinks |

## Requirements

- Windows PowerShell 5.1 **or** PowerShell 7+
- Network access to `192.168.1.1`
- A local UniFi admin account on the UCG Fiber

## Usage

```powershell
# Disable port 3 (prompts for password)
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3

# Re-enable port 3 — restores exact original config
.\Manage-UniFiPort.ps1 -Action Enable -PortNumber 3

# Check current live state of port 5
.\Manage-UniFiPort.ps1 -Action Status -PortNumber 5

# Supply password inline (useful in automation / Task Scheduler)
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 5 -Password "S3cur3!"

# Target a specific switch when multiple USW devices are adopted
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 5 -DeviceMac "aa:bb:cc:11:22:33"

# Dry-run — authenticates and shows what would change, applies nothing
.\Manage-UniFiPort.ps1 -Action Disable -PortNumber 3 -WhatIf
```

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Action` | Yes | — | `Disable`, `Enable`, or `Status` |
| `-PortNumber` | Yes | — | Port index 1–16 |
| `-Username` | No | `admin` | UniFi admin username |
| `-Password` | No | *(prompted)* | Admin password |
| `-ControllerUrl` | No | `https://192.168.1.1` | Base URL of the UCG Fiber |
| `-Site` | No | `default` | UniFi site name |
| `-DeviceMac` | No | *(auto-detect)* | MAC of the target switch |
| `-StateDir` | No | *(script folder)* | Directory for snapshot files |

## How It Works

### Authentication
The script posts credentials to `/api/auth/login` on the UCG Fiber (UniFi OS layout). The response sets a `TOKEN` cookie containing a JWT; the CSRF token is decoded from the JWT payload and attached as `X-CSRF-Token` on every subsequent call. The UCG Fiber's self-signed TLS certificate is bypassed automatically.

### Disable flow
1. Reads the current `port_overrides` entry for the target port from the controller.
2. Writes a snapshot of the original entry to `unifi_portN_state.json`.
3. Sets `disabled: true` on that entry (all other fields untouched) and `PUT`s the update to `/proxy/network/api/s/default/rest/device/<id>`.

The switch immediately brings the port down — no link, no PoE. The controller retains the full configuration.

### Enable flow
1. Reads `unifi_portN_state.json`.
2. If the port had an override before: restores that exact override (removing `disabled`).
3. If the port had no override before: removes the override entry entirely, returning the port to its default profile.
4. `PUT`s the restored state and deletes the snapshot file.

If the snapshot file is missing (e.g. lost between runs), the script falls back to simply removing the `disabled` flag from the current override, preserving whatever other settings are present.

### State file
```
unifi_port3_state.json   ← created on Disable, deleted on Enable
unifi_port5_state.json
...
```

Each file is self-contained — it records the controller URL, site, device MAC, and full original override so the Enable action can be run from any machine with the file present.

## Security Notes

- Credentials are never written to disk by this script.
- The `-Password` parameter is available for automation; prefer `-AsSecureString` prompts for interactive use.
- The snapshot files contain only port configuration metadata — no credentials.
- TLS validation is bypassed for the local self-signed certificate only; this is standard practice for local UniFi controllers.
