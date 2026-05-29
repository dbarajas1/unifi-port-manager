# UniFi Port Manager — Home Assistant Integration

Adds all switch ports as toggle entities in Home Assistant. Uses `port-api.js`
as a bridge so HA never talks to the UniFi controller directly.

```
HA rest_command  →  port-api.js (localhost:8765)  →  UniFi controller
```

## What you get

| Entity | Type | Description |
|---|---|---|
| `sensor.unifi_switch_ports` | Sensor | Bulk poll, all port data as JSON attributes |
| `sensor.unifi_port_N_link` | Sensor | Link state per port (`up` / `down`) |
| `switch.unifi_port_N` | Switch | Toggle to disable / enable each port |

Polling interval: 60 seconds (adjust `scan_interval` in `packages/unifi_ports.yaml`).

## Prerequisites

1. `Setup-Config.ps1` has been run — `port-config.json` exists and the password is in the Keychain.
2. `port-api.js` is running (see **Start as a background service** below).
3. Home Assistant can reach `http://localhost:8765` — either it runs on the same Mac, or you expose the port via Tailscale or SSH tunnel.

## Installation

### 1. Add the API token to HA secrets

Open your HA `secrets.yaml` and add:

```yaml
unifi_api_token: "paste-your-token-here"
```

The token is in `port-config.json` (`apiToken` field) and was printed by `Setup-Config.ps1`.

### 2. Enable packages in configuration.yaml

Add this block to your HA `configuration.yaml` (skip if you already use packages):

```yaml
homeassistant:
  packages: !include_dir_named packages
```

Then copy (or symlink) the `packages/` folder from this directory into your HA config directory:

```bash
cp -r packages/ /path/to/your/ha/config/packages/
```

### 3. Restart Home Assistant

Settings → System → Restart.

### 4. Add the dashboard card

In a dashboard: **Edit → Add Card → Manual** and paste the contents of
`lovelace/unifi_ports_card.yaml`.

### 5. Rename ports to match your cabling

Settings → Entities → search "UniFi Port" → click a port → set a friendly name
(e.g. "Server Room", "CCTV Cam 1", "Guest WiFi AP"). The name appears on the card.

## Start as a background service (macOS)

```bash
# 1. Edit the plist — replace YOUR_HOME_PATH with your actual home directory
#    e.g.  /Users/dbarajas
nano homeassistant/launchd/com.unifi.port-api.plist

# 2. Install
cp homeassistant/launchd/com.unifi.port-api.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.unifi.port-api.plist

# 3. Verify it started
launchctl list | grep unifi
tail -20 /tmp/unifi-port-api.log
```

To stop the service:
```bash
launchctl unload ~/Library/LaunchAgents/com.unifi.port-api.plist
```

## Automation example

Trigger on any port losing link (e.g. alert if an uplink goes down):

```yaml
automation:
  - alias: "Alert: uplink port went down"
    trigger:
      - platform: state
        entity_id: sensor.unifi_port_9_link
        to: "down"
    action:
      - service: notify.mobile_app_your_phone
        data:
          title: "Network Alert"
          message: "SFP port 9 link is down"
```

Trigger on a port being disabled:

```yaml
automation:
  - alias: "Log port disable events"
    trigger:
      - platform: state
        entity_id:
          - switch.unifi_port_1
          - switch.unifi_port_2
          - switch.unifi_port_3
        to: "off"
    action:
      - service: logbook.log
        data:
          name: "UniFi"
          message: "{{ trigger.to_state.name }} was disabled"
```

## Troubleshooting

**Entities show as unavailable:**
- Check `tail -20 /tmp/unifi-port-api.log` — the server may have crashed.
- Verify the API token in `secrets.yaml` matches `port-config.json`.
- Try `curl -s http://localhost:8765/health` from the machine running HA.

**Toggle has no effect / takes > 60s to reflect:**
- The REST sensor polls every 60 seconds. State changes via the toggle are applied
  immediately to the controller but the sensor won't reflect the new state until
  the next poll cycle.
- Reduce `scan_interval` in `packages/unifi_ports.yaml` for faster feedback (minimum ~10s).

**HA is on a different machine than port-api.js:**
- Use Tailscale: start the server with `LISTEN_ADDR=0.0.0.0 node port-api.js` and
  replace `localhost` in `unifi_ports.yaml` with the Tailscale IP of the Mac.
- Or SSH tunnel: `ssh -L 8765:localhost:8765 user@mac-hostname` and keep it open.
