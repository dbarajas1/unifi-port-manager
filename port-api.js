#!/usr/bin/env node
// HTTP API server for remote UniFi port management.
//
// Setup: run Setup-Config.ps1 first to create port-config.json and store the password.
// Start: UNIFI_PASSWORD=<pass> node port-api.js
//        (or store password in macOS Keychain via Setup-Config.ps1 — no env var needed)
//
// Endpoints (all except /health require X-API-Token header):
//   GET  /health                       — liveness check, no auth
//   GET  /ports[?device=<name>]        — all ports on default (or named) device
//   GET  /ports/:n[?device=<name>]     — single port status
//   POST /ports/:n/disable[?device=…]  — disable port
//   POST /ports/:n/enable[?device=…]   — enable port (restores snapshot)
//
// Remote access via SSH tunnel:
//   ssh -L 8765:localhost:8765 user@your-mac
//   curl -s -H "X-API-Token: <token>" http://localhost:8765/ports?device=SJ-FW-01

'use strict';

const http  = require('http');
const https = require('https');
const fs    = require('fs');
const path  = require('path');
const { execSync } = require('child_process');

// ── Config ────────────────────────────────────────────────────────────────────
const configPath = path.join(__dirname, 'port-config.json');
if (!fs.existsSync(configPath)) {
  console.error('Error: port-config.json not found. Run Setup-Config.ps1 first.');
  process.exit(1);
}

const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const { controllerUrl, site = 'default', username, deviceName, ucgFiberName, apiToken } = cfg;
const listenPort    = parseInt(process.env.PORT || cfg.apiPort || 8765, 10);
const listenAddress = process.env.LISTEN_ADDR || '127.0.0.1';

if (!apiToken || apiToken === 'REPLACE_WITH_A_LONG_RANDOM_SECRET') {
  console.error('Error: apiToken not configured. Run Setup-Config.ps1 first.');
  process.exit(1);
}

if (!deviceName) {
  console.error('Error: deviceName not set in port-config.json. Run Setup-Config.ps1 first.');
  process.exit(1);
}

// ── Password resolution ───────────────────────────────────────────────────────
let controllerPassword = process.env.UNIFI_PASSWORD;

if (!controllerPassword) {
  try {
    const host    = new URL(controllerUrl).hostname;
    const service = `unifi-port-manager-${host}`;
    controllerPassword = execSync(
      `security find-generic-password -s "${service}" -a "${username}" -w`,
      { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }
    ).trim();
  } catch (_) {}
}

if (!controllerPassword) {
  console.error('Error: password not found. Set UNIFI_PASSWORD env var or run Setup-Config.ps1 to save it to the Keychain.');
  process.exit(1);
}

// ── UniFi API helpers ─────────────────────────────────────────────────────────
const tlsAgent = new https.Agent({ rejectUnauthorized: false });

function request(options, body) {
  return new Promise((resolve, reject) => {
    const parsed  = new URL(options.url);
    const reqBody = body ? JSON.stringify(body) : null;
    const headers = {
      'Content-Type':  'application/json',
      Accept:          'application/json',
      ...options.headers,
    };
    if (reqBody) headers['Content-Length'] = Buffer.byteLength(reqBody);

    const req = https.request({
      hostname: parsed.hostname,
      port:     parsed.port || 443,
      path:     parsed.pathname + (parsed.search || ''),
      method:   options.method || 'GET',
      headers,
      agent:    tlsAgent,
    }, (res) => {
      const cookies = res.headers['set-cookie'] || [];
      let data = '';
      res.on('data', c => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, cookies, body: data }));
    });
    req.on('error', reject);
    if (reqBody) req.write(reqBody);
    req.end();
  });
}

async function login() {
  const res = await request(
    { url: `${controllerUrl}/api/auth/login`, method: 'POST' },
    { username, password: controllerPassword }
  );
  if (res.status !== 200) throw new Error(`Login failed: HTTP ${res.status} — ${res.body}`);

  const tokenCookie = res.cookies.map(c => c.split(';')[0]).find(c => c.startsWith('TOKEN='));
  if (!tokenCookie) throw new Error('TOKEN cookie not found in login response');
  const token = tokenCookie.slice('TOKEN='.length);

  const payload = JSON.parse(
    Buffer.from(
      token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'),
      'base64'
    ).toString('utf8')
  );
  if (!payload.csrfToken) throw new Error('csrfToken not in JWT payload');

  return { token, csrf: payload.csrfToken };
}

function authHeaders(csrf, token) {
  return { 'X-CSRF-Token': csrf, Cookie: `TOKEN=${token}` };
}

async function getDevices(csrf, token) {
  const res = await request({
    url:     `${controllerUrl}/proxy/network/api/s/${site}/stat/device`,
    headers: authHeaders(csrf, token),
  });
  return JSON.parse(res.body).data;
}

async function putDevice(deviceId, body, csrf, token) {
  const res = await request(
    { url: `${controllerUrl}/proxy/network/api/s/${site}/rest/device/${deviceId}`, method: 'PUT', headers: authHeaders(csrf, token) },
    body
  );
  return JSON.parse(res.body);
}

async function logout(csrf, token) {
  try {
    await request({ url: `${controllerUrl}/api/auth/logout`, method: 'POST', headers: authHeaders(csrf, token) });
  } catch (_) {}
}

// ── Port state file helpers ───────────────────────────────────────────────────
// Default device uses the short form (backward-compatible with Manage-UniFiPort.ps1).
// Non-default devices get a device-prefixed filename to avoid port-index collisions.
const stateDir = __dirname;
function stateFile(n, targetDevice) {
  if (targetDevice === deviceName) {
    return path.join(stateDir, `unifi_port${n}_state.json`);
  }
  const slug = targetDevice.replace(/[^a-zA-Z0-9]/g, '_');
  return path.join(stateDir, `unifi_${slug}_port${n}_state.json`);
}

// ── Port operations ───────────────────────────────────────────────────────────
// targetDevice defaults to the primary switch from port-config.json.
// Pass a different name (e.g. ucgFiberName) to operate on the UCG Fiber.

async function portStatus(portNum, targetDevice = deviceName) {
  const { token, csrf } = await login();
  try {
    const devices   = await getDevices(csrf, token);
    const sw        = devices.find(d => d.name === targetDevice);
    if (!sw) throw new Error(`Device '${targetDevice}' not found`);

    const override  = (sw.port_overrides || []).find(o => o.port_idx === portNum) || null;
    const portEntry = (sw.port_table     || []).find(p => p.port_idx === portNum) || null;
    const sf        = stateFile(portNum, targetDevice);
    const snapshot  = fs.existsSync(sf) ? JSON.parse(fs.readFileSync(sf, 'utf8')) : null;

    return {
      port:               portNum,
      device:             sw.name,
      model:              sw.model,
      mac:                sw.mac,
      disabled:           !!(override && override.forward === 'disabled'),
      link:               portEntry ? (portEntry.up ? 'up' : 'down') : 'unknown',
      override:           override,
      snapshotPresent:    !!snapshot,
      snapshotCapturedAt: snapshot ? snapshot.captured_at : null,
    };
  } finally {
    await logout(csrf, token);
  }
}

async function disablePort(portNum, targetDevice = deviceName) {
  const { token, csrf } = await login();
  try {
    const devices   = await getDevices(csrf, token);
    const sw        = devices.find(d => d.name === targetDevice);
    if (!sw) throw new Error(`Device '${targetDevice}' not found`);

    const overrides = (sw.port_overrides || []).map(o => ({ ...o }));
    const existing  = overrides.find(o => o.port_idx === portNum) || null;

    if (existing && existing.forward === 'disabled') {
      return { ok: true, message: `Port ${portNum} is already disabled`, changed: false };
    }

    // Save snapshot before making any change
    fs.writeFileSync(stateFile(portNum, targetDevice), JSON.stringify({
      captured_at:       new Date().toISOString(),
      controller_url:    controllerUrl,
      site,
      device_mac:        sw.mac,
      device_name:       sw.name,
      port_idx:          portNum,
      had_override:      !!existing,
      original_override: existing,
    }, null, 2));

    const newOverride = { ...(existing || { port_idx: portNum }) };
    newOverride.forward                    = 'disabled';
    newOverride.setting_preference         = 'auto';
    newOverride.native_networkconf_id      = '';
    newOverride.port_security_mac_address  = [];
    newOverride.stp_edge_state             = 'auto';
    newOverride.stp_bpdu_guard_enabled     = false;

    const newOverrides = [...overrides.filter(o => o.port_idx !== portNum), newOverride];
    const result = await putDevice(sw._id, { port_overrides: newOverrides }, csrf, token);
    if (result.meta?.rc !== 'ok') throw new Error(`API error: ${JSON.stringify(result.meta)}`);

    // Verify
    await new Promise(r => setTimeout(r, 800));
    const verify    = await getDevices(csrf, token);
    const verifyDev = verify.find(d => d.mac === sw.mac);
    const verifyOv  = (verifyDev?.port_overrides || []).find(o => o.port_idx === portNum);
    if (!verifyOv || verifyOv.forward !== 'disabled') {
      fs.unlinkSync(stateFile(portNum, targetDevice));
      throw new Error('Port disable did not stick after re-fetch verification');
    }

    return { ok: true, message: `Port ${portNum} disabled on ${sw.name}`, changed: true };
  } finally {
    await logout(csrf, token);
  }
}

async function enablePort(portNum, targetDevice = deviceName) {
  const { token, csrf } = await login();
  try {
    const devices = await getDevices(csrf, token);
    const sw      = devices.find(d => d.name === targetDevice);
    if (!sw) throw new Error(`Device '${targetDevice}' not found`);

    const overrides = (sw.port_overrides || []).map(o => ({ ...o }));
    const sf        = stateFile(portNum, targetDevice);
    let   newOverrides;

    if (fs.existsSync(sf)) {
      const snapshot = JSON.parse(fs.readFileSync(sf, 'utf8'));
      if (snapshot.had_override && snapshot.original_override) {
        newOverrides = [...overrides.filter(o => o.port_idx !== portNum), { ...snapshot.original_override }];
      } else {
        newOverrides = overrides.filter(o => o.port_idx !== portNum);
      }
    } else {
      const existing = overrides.find(o => o.port_idx === portNum);
      if (!existing || existing.forward !== 'disabled') {
        return { ok: true, message: `Port ${portNum} is not disabled`, changed: false };
      }
      newOverrides = overrides.filter(o => o.port_idx !== portNum);
    }

    const result = await putDevice(sw._id, { port_overrides: newOverrides }, csrf, token);
    if (result.meta?.rc !== 'ok') throw new Error(`API error: ${JSON.stringify(result.meta)}`);

    if (fs.existsSync(sf)) fs.unlinkSync(sf);
    return { ok: true, message: `Port ${portNum} enabled on ${sw.name} — config restored`, changed: true };
  } finally {
    await logout(csrf, token);
  }
}

async function allPortsStatus(targetDevice = deviceName) {
  const { token, csrf } = await login();
  try {
    const devices = await getDevices(csrf, token);
    const sw      = devices.find(d => d.name === targetDevice);
    if (!sw) throw new Error(`Device '${targetDevice}' not found`);

    const overrides = sw.port_overrides || [];
    const portTable = (sw.port_table || []).sort((a, b) => a.port_idx - b.port_idx);

    const ports = portTable.map(pt => {
      const n        = pt.port_idx;
      const override = overrides.find(o => o.port_idx === n) || null;
      const sf       = stateFile(n, targetDevice);
      const snapshot = fs.existsSync(sf) ? JSON.parse(fs.readFileSync(sf, 'utf8')) : null;
      return {
        port:               n,
        name:               override?.name || pt.name || `Port ${n}`,
        disabled:           !!(override && override.forward === 'disabled'),
        link:               pt.up ? 'up' : 'down',
        speed:              pt.speed || 0,
        poe_mode:           pt.poe_mode || null,
        media:              pt.media || null,
        snapshotPresent:    !!snapshot,
        snapshotCapturedAt: snapshot ? snapshot.captured_at : null,
      };
    });

    return {
      device:    sw.name,
      model:     sw.model,
      type:      sw.type,
      mac:       sw.mac,
      ip:        sw.ip,
      ports,
      timestamp: new Date().toISOString(),
    };
  } finally {
    await logout(csrf, token);
  }
}

// ── HTTP server ───────────────────────────────────────────────────────────────
function send(res, status, body) {
  const json = JSON.stringify(body, null, 2);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(json) });
  res.end(json);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    return send(res, 200, {
      ok: true,
      devices: { switch: deviceName, ucgFiber: ucgFiberName || null },
      controller: controllerUrl,
    });
  }

  if (req.headers['x-api-token'] !== apiToken) {
    return send(res, 401, { error: 'Unauthorized — supply X-API-Token header' });
  }

  // ?device= query param selects the target device; defaults to primary switch
  const targetDevice = url.searchParams.get('device') || deviceName;

  // Bulk: all ports in one call
  if (req.method === 'GET' && url.pathname === '/ports') {
    try { return send(res, 200, await allPortsStatus(targetDevice)); }
    catch (err) {
      console.error('[ERROR] GET /ports —', err.message);
      return send(res, 500, { error: err.message });
    }
  }

  const m = url.pathname.match(/^\/ports\/(\d+)(?:\/(disable|enable))?$/);
  if (!m) {
    return send(res, 404, {
      error: 'Not found',
      routes: [
        'GET  /health',
        'GET  /ports[?device=<name>]              — all ports',
        'GET  /ports/:n[?device=<name>]           — single port',
        'POST /ports/:n/disable[?device=<name>]',
        'POST /ports/:n/enable[?device=<name>]',
      ],
    });
  }

  const portNum = parseInt(m[1], 10);
  if (portNum < 1 || portNum > 16) return send(res, 400, { error: 'Port must be 1–16' });

  try {
    if (req.method === 'GET' && !m[2]) {
      return send(res, 200, await portStatus(portNum, targetDevice));
    }
    if (req.method === 'POST' && m[2] === 'disable') {
      return send(res, 200, await disablePort(portNum, targetDevice));
    }
    if (req.method === 'POST' && m[2] === 'enable') {
      return send(res, 200, await enablePort(portNum, targetDevice));
    }
    return send(res, 405, { error: 'Method not allowed' });
  } catch (err) {
    console.error(`[ERROR] ${req.method} ${url.pathname} —`, err.message);
    return send(res, 500, { error: err.message });
  }
});

server.listen(listenPort, listenAddress, () => {
  console.log(`UniFi Port API  →  http://${listenAddress}:${listenPort}`);
  console.log(`Primary switch : ${deviceName}`);
  if (ucgFiberName) console.log(`UCG Fiber      : ${ucgFiberName}`);
  console.log(`Controller     : ${controllerUrl}`);
  console.log('');
  console.log('Endpoints (X-API-Token header required except /health):');
  console.log(`  GET  /health`);
  console.log(`  GET  /ports                         ← switch ports`);
  console.log(`  GET  /ports?device=${ucgFiberName || 'SJ-FW-01'}   ← UCG Fiber ports`);
  console.log(`  GET  /ports/:n`);
  console.log(`  POST /ports/:n/disable`);
  console.log(`  POST /ports/:n/enable`);
  console.log('');
  console.log('Remote access via SSH tunnel:');
  console.log(`  ssh -L ${listenPort}:localhost:${listenPort} user@$(hostname -s)`);
  console.log(`  curl -s -H "X-API-Token: <token>" http://localhost:${listenPort}/ports`);
  console.log('');
  console.log('Or use Tailscale (set LISTEN_ADDR=0.0.0.0 to bind on all interfaces).');
});
