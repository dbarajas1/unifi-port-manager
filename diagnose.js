/**
 * UniFi port-disable diagnostic
 * Logs in via API + browser, probes port state before/after a test PUT,
 * and writes a JSON report + screenshots to ./diag-output/.
 *
 * Usage:
 *   UNIFI_PASSWORD=xxx node diagnose.js
 *   node diagnose.js          (prompts for password via stdin)
 */

const { chromium } = require('playwright');
const https        = require('https');
const readline     = require('readline');
const fs           = require('fs');
const path         = require('path');

const CONTROLLER  = process.env.UNIFI_CONTROLLER  || 'https://192.168.1.1';
const USERNAME    = process.env.UNIFI_USERNAME    || 'admin';
const SITE        = process.env.UNIFI_SITE        || 'default';
const TARGET_PORT = parseInt(process.env.UNIFI_PORT || '1', 10);
const DEVICE_NAME = process.env.UNIFI_DEVICE      || '';
const OUT_DIR     = path.join(__dirname, 'diag-output');

function prompt(question) {
  return new Promise(resolve => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, answer => { rl.close(); resolve(answer); });
  });
}

function apiCall(method, urlPath, body, cookieHdr, csrfToken) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const options = {
      hostname: '192.168.1.1',
      port: 443,
      path: urlPath,
      method,
      rejectUnauthorized: false,
      headers: Object.assign(
        { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        cookieHdr   ? { 'Cookie': cookieHdr }           : {},
        csrfToken   ? { 'X-CSRF-Token': csrfToken }     : {},
        payload     ? { 'Content-Length': Buffer.byteLength(payload) } : {}
      )
    };
    const req = https.request(options, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        resolve({
          status:     res.statusCode,
          rawCookies: res.headers['set-cookie'] || [],
          body:       (() => { try { return JSON.parse(data); } catch { return data; } })()
        });
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function extractCsrf(jwt) {
  const seg = jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
  const pad = (4 - seg.length % 4) % 4;
  return JSON.parse(Buffer.from(seg + '='.repeat(pad), 'base64').toString('utf8')).csrfToken;
}

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const report = { steps: [], errors: [] };

  const password = process.env.UNIFI_PASSWORD || await prompt(`Password for ${USERNAME}: `);

  // ── 1. API Login ──────────────────────────────────────────────────────────────
  console.log('\n[1] API login ...');
  const loginRes = await apiCall('POST', '/api/auth/login', { username: USERNAME, password });
  report.steps.push({ step: 'api_login', status: loginRes.status });

  if (loginRes.status !== 200) {
    console.error('    FAILED:', JSON.stringify(loginRes.body));
    report.errors.push({ step: 'api_login', detail: loginRes.body });
    fs.writeFileSync(path.join(OUT_DIR, 'report.json'), JSON.stringify(report, null, 2));
    process.exit(1);
  }
  console.log('    OK — HTTP ' + loginRes.status);

  const cookieHdr  = loginRes.rawCookies.map(c => c.split(';')[0]).join('; ');
  const tokenVal   = loginRes.rawCookies.map(c => c.split(';')[0]).find(c => c.startsWith('TOKEN='));
  const csrfToken  = extractCsrf(tokenVal.replace('TOKEN=', ''));

  // ── 2. List all devices ───────────────────────────────────────────────────────
  console.log('[2] Fetching devices ...');
  const devRes = await apiCall('GET', `/proxy/network/api/s/${SITE}/stat/device`, null, cookieHdr, csrfToken);
  const allDevices = devRes.body && devRes.body.data ? devRes.body.data : [];
  report.allDevices = allDevices.map(d => ({ name: d.name, model: d.model, mac: d.mac, type: d.type }));
  console.log('    Devices found: ' + allDevices.map(d => `${d.name}(${d.model})`).join(', '));

  const device = allDevices.find(d => d.name === DEVICE_NAME) || allDevices.find(d => d.type === 'usw');
  if (!device) {
    console.error('    Target device not found.');
    report.errors.push({ step: 'find_device', detail: 'not found' });
    fs.writeFileSync(path.join(OUT_DIR, 'report.json'), JSON.stringify(report, null, 2));
    process.exit(1);
  }
  console.log(`    Using: ${device.name}  model=${device.model}  id=${device._id}`);
  report.targetDevice = { name: device.name, model: device.model, mac: device.mac, id: device._id };

  // ── 3. Before state ───────────────────────────────────────────────────────────
  const beforeOverrides = Array.isArray(device.port_overrides) ? device.port_overrides : [];
  const beforePort      = beforeOverrides.find(p => p.port_idx === TARGET_PORT) || null;
  console.log(`[3] Port ${TARGET_PORT} override BEFORE: ${JSON.stringify(beforePort)}`);
  report.before = { all_overrides: beforeOverrides, target_port_override: beforePort };

  // ── 4. PUT with disabled=true ─────────────────────────────────────────────────
  const newOverride  = Object.assign({}, beforePort || { port_idx: TARGET_PORT }, { disabled: true });
  const otherPorts   = beforeOverrides.filter(p => p.port_idx !== TARGET_PORT);
  const newOverrides = [...otherPorts, newOverride];
  const putBody      = { port_overrides: newOverrides };

  console.log(`[4] Sending PUT ...`);
  console.log(`    Body: ${JSON.stringify(putBody)}`);
  report.putBody = putBody;

  const putRes = await apiCall('PUT', `/proxy/network/api/s/${SITE}/rest/device/${device._id}`, putBody, cookieHdr, csrfToken);
  console.log(`    HTTP status : ${putRes.status}`);
  console.log(`    meta.rc     : ${putRes.body && putRes.body.meta ? putRes.body.meta.rc : 'N/A'}`);
  console.log(`    Returned overrides: ${JSON.stringify(putRes.body && putRes.body.data && putRes.body.data[0] ? putRes.body.data[0].port_overrides : 'none')}`);
  report.putResponse = {
    status:           putRes.status,
    meta:             putRes.body && putRes.body.meta,
    returnedOverrides: putRes.body && putRes.body.data && putRes.body.data[0] && putRes.body.data[0].port_overrides
  };

  // ── 5. Re-fetch and verify ────────────────────────────────────────────────────
  console.log('[5] Re-fetching device to verify ...');
  await new Promise(r => setTimeout(r, 1000));
  const verifyRes  = await apiCall('GET', `/proxy/network/api/s/${SITE}/stat/device/${device._id}`, null, cookieHdr, csrfToken);
  const verifyDev  = verifyRes.body && verifyRes.body.data && verifyRes.body.data[0];
  const afterPort  = verifyDev ? (verifyDev.port_overrides || []).find(p => p.port_idx === TARGET_PORT) || null : null;
  report.after     = { all_overrides: verifyDev && verifyDev.port_overrides, target_port_override: afterPort };
  report.verified  = !!(afterPort && afterPort.disabled === true);
  console.log(`    Port ${TARGET_PORT} override AFTER: ${JSON.stringify(afterPort)}`);
  console.log(`    disabled=true confirmed: ${report.verified}`);

  // ── 6. Browser screenshot ─────────────────────────────────────────────────────
  console.log('[6] Launching browser ...');
  const browser = await chromium.launch({ headless: true, ignoreHTTPSErrors: true });
  const page    = await browser.newPage();
  const netLog  = [];
  page.on('response', async resp => {
    if (resp.url().includes('/api/')) {
      const body = await resp.json().catch(() => null);
      netLog.push({ url: resp.url(), status: resp.status(), body });
    }
  });

  try {
    await page.goto(`${CONTROLLER}/login`, { waitUntil: 'networkidle', timeout: 15000 });
    await page.screenshot({ path: path.join(OUT_DIR, '01-login-page.png') });

    const userSel = 'input[name="username"], input[type="text"]';
    const passSel = 'input[name="password"], input[type="password"]';
    await page.fill(userSel, USERNAME).catch(() => {});
    await page.fill(passSel, password).catch(() => {});
    await page.screenshot({ path: path.join(OUT_DIR, '02-creds-filled.png') });

    await Promise.all([
      page.waitForNavigation({ timeout: 15000 }).catch(() => {}),
      page.click('button[type="submit"]').catch(() =>
        page.keyboard.press('Enter').catch(() => {}))
    ]);
    await page.waitForTimeout(4000);
    await page.screenshot({ path: path.join(OUT_DIR, '03-post-login.png') });
    report.browser = { postLoginUrl: page.url() };
    console.log(`    Post-login URL: ${page.url()}`);

    // Navigate to device ports
    const portsUrl = `${CONTROLLER}/network/default/devices/${device._id}/ports`;
    await page.goto(portsUrl, { waitUntil: 'networkidle', timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(2000);
    await page.screenshot({ path: path.join(OUT_DIR, '04-device-ports.png') });
    console.log('    Port page screenshot saved.');
  } catch (e) {
    console.error('    Browser error:', e.message);
    report.errors.push({ step: 'browser', detail: e.message });
    await page.screenshot({ path: path.join(OUT_DIR, 'error.png') }).catch(() => {});
  }
  report.browserNetLog = netLog;
  await browser.close();

  // ── 7. Revert test ────────────────────────────────────────────────────────────
  console.log('[7] Reverting test disable ...');
  const revertOverrides = beforePort ? [...otherPorts, beforePort] : otherPorts;
  const revertRes = await apiCall('PUT', `/proxy/network/api/s/${SITE}/rest/device/${device._id}`,
                                  { port_overrides: revertOverrides }, cookieHdr, csrfToken);
  console.log(`    Revert rc: ${revertRes.body && revertRes.body.meta ? revertRes.body.meta.rc : revertRes.status}`);

  fs.writeFileSync(path.join(OUT_DIR, 'report.json'), JSON.stringify(report, null, 2));

  console.log('\n════════════════ SUMMARY ════════════════');
  console.log(`API login      : ${report.steps[0].status === 200 ? 'OK' : 'FAILED'}`);
  console.log(`Device         : ${device.name} (${device.model})`);
  console.log(`Port ${TARGET_PORT} before  : ${JSON.stringify(beforePort)}`);
  console.log(`PUT status     : HTTP ${putRes.status}  rc=${putRes.body && putRes.body.meta ? putRes.body.meta.rc : '?'}`);
  console.log(`Port ${TARGET_PORT} after   : ${JSON.stringify(afterPort)}`);
  console.log(`Disable worked : ${report.verified ? 'YES' : 'NO — false positive'}`);
  console.log(`Report         : diag-output/report.json`);
  console.log(`Screenshots    : diag-output/*.png`);
  console.log('════════════════════════════════════════');
})();
