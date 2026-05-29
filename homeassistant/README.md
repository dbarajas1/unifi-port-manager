# UniFi Port Manager — Home Assistant Integration

Adds all switch ports as toggle entities in Home Assistant. `port-api.js`
runs as a bridge so HA never talks to the UniFi controller directly.

```
HA rest_command  →  port-api.js (:8765)  →  UniFi controller
```

## What you get

| Entity | Type | Description |
|---|---|---|
| `sensor.unifi_switch_ports` | Sensor | Bulk poll — switch port data as attributes |
| `sensor.unifi_ucg_ports` | Sensor | Bulk poll — UCG Fiber port data as attributes |
| `sensor.unifi_port_N_link` | Sensor | Link state per switch port (`up` / `down`) |
| `sensor.unifi_fw_port_N_link` | Sensor | Link state per UCG Fiber port |
| `switch.unifi_port_N` | Switch | Toggle — disable / enable switch port |
| `switch.unifi_fw_port_N` | Switch | Toggle — disable / enable UCG Fiber port |

Polling interval: 60 s (adjust `scan_interval` in `packages/unifi_ports.yaml`).

---

## Option A — Home Assistant OS (recommended)

The `addon/` directory at the root of this repo is a proper HA Supervisor add-on.
It runs `port-api.js` inside a Docker container managed by HA, with credentials
entered through the normal HA add-on UI. Nothing to install on the Mac.

### 1. Add the repository to HA

Settings → Add-ons → Add-on store → ⋮ (top-right) → **Repositories** → paste:

```
https://github.com/dbarajas1/unifi-port-manager
```

The **UniFi Port Manager** add-on will appear in the store.

### 2. Install and configure the add-on

- Click **Install**.
- Go to the **Configuration** tab and fill in:

| Field | Value |
|---|---|
| `controllerUrl` | `https://192.168.1.1` |
| `site` | `default` |
| `username` | `svc_automation` |
| `password` | *(your controller password)* |
| `deviceName` | `SJ-UP-SW-01` |
| `ucgFiberName` | `SJ-FW-01` |
| `apiPort` | `8765` |
| `apiToken` | *(generate a long random string — see tip below)* |

**Tip — generate a token** (run in any terminal):
```bash
node -e "console.log(require('crypto').randomBytes(36).toString('base64'))"
# or
openssl rand -base64 36
```

- Click **Save**, then **Start** the add-on.
- Check the **Log** tab — you should see `UniFi Port Manager starting...`.

### 3. Add the API token to HA secrets

Open your HA `secrets.yaml` (in the HA config directory, e.g. via the File editor add-on):

```yaml
unifi_api_token: "paste-the-same-token-you-entered-above"
```

### 4. Install the HA config package

Copy `packages/unifi_ports.yaml` into your HA config's `packages/` folder.
If you don't have a packages folder yet, enable it in `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

Then place the file:
```
/config/packages/unifi_ports.yaml
```

### 5. Restart Home Assistant

Settings → System → Restart (full restart, not just reload).

### 6. Add the dashboard card

Dashboard → Edit → Add Card → **Manual** → paste `lovelace/unifi_ports_card.yaml`.

### 7. Rename ports to match your cabling

Settings → Entities → search "UniFi Port" → click any entry → set a friendly name
(e.g. "Server Room NAS", "CCTV Cam 2"). The name shows up on the card automatically.

---

## Option B — macOS (standalone, no HAOS add-on)

Use this if HA runs elsewhere and you want `port-api.js` running on the Mac.

### Start as a background service

```bash
# 1. Edit the plist — replace YOUR_HOME_PATH with your actual home directory
nano homeassistant/launchd/com.unifi.port-api.plist

# 2. Install
cp homeassistant/launchd/com.unifi.port-api.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.unifi.port-api.plist

# 3. Verify
launchctl list | grep unifi
tail -20 /tmp/unifi-port-api.log
```

### Point HA at the Mac

Replace `localhost` in `packages/unifi_ports.yaml` with the Mac's IP or Tailscale
address (e.g. `http://192.168.1.50:8765/ports`).

---

## Automation examples

Alert when an uplink loses link:

```yaml
automation:
  - alias: "Alert: switch uplink down"
    trigger:
      - platform: state
        entity_id: sensor.unifi_port_9_link
        to: "down"
    action:
      - service: notify.mobile_app_your_phone
        data:
          title: "Network Alert"
          message: "Switch SFP uplink (port 9) is down"
```

Log every port disable event:

```yaml
automation:
  - alias: "Log port disable"
    trigger:
      - platform: state
        entity_id:
          - switch.unifi_port_1
          - switch.unifi_port_2
          - switch.unifi_port_3
          - switch.unifi_port_4
        to: "off"
    action:
      - service: logbook.log
        data:
          name: "UniFi"
          message: "{{ trigger.to_state.attributes.friendly_name }} was disabled"
```

---

## Troubleshooting

**Entities show as unavailable:**
- Add-on: check the add-on **Log** tab in HA for errors.
- Mac: `curl -s http://localhost:8765/health` from the HA host.
- Confirm `unifi_api_token` in `secrets.yaml` matches the add-on config.

**Toggle has no effect / state takes >60 s to update:**
- Actions apply immediately to the controller. The REST sensor polls every 60 s,
  so the HA state catches up on the next cycle.
- Reduce `scan_interval` in `packages/unifi_ports.yaml` for faster feedback.

**Add-on not visible in store after adding repo:**
- Hard-refresh the browser.
- Check HA → Settings → System → Logs for repository errors.
- Confirm the repo URL is exactly `https://github.com/dbarajas1/unifi-port-manager`.
