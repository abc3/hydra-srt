import { test, expect } from '@playwright/test';
import { spawn } from 'node:child_process';
import net from 'node:net';
import dgram from 'node:dgram';

function freeTcpPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function freeUdpPort() {
  return new Promise((resolve, reject) => {
    const sock = dgram.createSocket('udp4');
    sock.on('error', reject);
    sock.bind(0, '127.0.0.1', () => {
      const { port } = sock.address();
      sock.close(() => resolve(port));
    });
  });
}

function runProcess(cmd, args, tag) {
  const p = spawn(cmd, args, { stdio: 'inherit' });
  const done = new Promise((resolve) => {
    p.on('exit', (code) => resolve(code ?? 0));
  });
  return { proc: p, done, tag };
}

async function apiJson(request, url, token, body) {
  const resp = await request.post(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    data: body,
  });
  if (!resp.ok()) {
    const status = resp.status();
    const text = await resp.text();
    throw new Error(`API ${url} failed: status=${status} body=${text}`);
  }
  return await resp.json();
}

test('route Overview/Statistics show live throughput (full-stack)', async ({ page, request, baseURL }) => {
  // UI login
  await page.goto(`${baseURL}/#/login`);
  await page.getByPlaceholder('Username').fill('admin');
  await page.getByPlaceholder('Password').fill('password123');
  await page.getByRole('button', { name: 'Sign In' }).click();
  await expect(page.getByRole('heading', { name: /Dashboard/i })).toBeVisible();

  // Token is stored by the UI in localStorage under key "token"
  const token = await page.evaluate(() => window.localStorage.getItem('token'));
  expect(token).toBeTruthy();

  const sourcePort = await freeTcpPort();
  const udpDestPort = await freeUdpPort();

  // Create route + UDP destination via API (so native pipeline has at least one sink that always counts bytes)
  const routeResp = await apiJson(
    request,
    `${baseURL}/api/routes`,
    token,
    {
      route: {
        name: 'pw_route_stats',
        exportStats: false,
        schema: 'SRT',
        schema_options: { localaddress: '127.0.0.1', localport: sourcePort, mode: 'listener' },
      },
    },
  );
  const routeId = routeResp?.data?.id;
  expect(routeId).toBeTruthy();

  await apiJson(
    request,
    `${baseURL}/api/routes/${routeId}/destinations`,
    token,
    {
      destination: {
        name: 'pw_udp_dest',
        schema: 'UDP',
        schema_options: { host: '127.0.0.1', port: udpDestPort },
      },
    },
  );

  // Start route
  const startResp = await request.get(`${baseURL}/api/routes/${routeId}/start`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(startResp.ok()).toBeTruthy();

  // Feed the SRT listener with a short ffmpeg sender
  const ffmpeg = runProcess(
    'ffmpeg',
    [
      '-hide_banner',
      '-loglevel',
      'error',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1280x720:rate=30',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=48000',
      '-t',
      '6',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-tune',
      'zerolatency',
      '-pix_fmt',
      'yuv420p',
      '-g',
      '60',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-ar',
      '48000',
      '-ac',
      '2',
      '-f',
      'mpegts',
      `srt://127.0.0.1:${sourcePort}?mode=caller`,
    ],
    'ffmpeg',
  );

  // Open the route page and wait for KPIs to populate
  await page.goto(`${baseURL}/#/routes/${routeId}`);

  const sourceKpi = page.getByTestId('kpi-source-bitrate');
  const worstDestKpi = page.getByTestId('kpi-worst-dest-bitrate');

  await expect(sourceKpi).toContainText(/\d[\d,]*\s*bps/);
  await expect(worstDestKpi).toContainText(/\d[\d,]*\s*bps/);

  // Switch to Statistics and ensure we see a live bitrate cell (not N/A)
  await page.getByRole('tab', { name: 'Statistics' }).click();
  await expect(page.locator('text=/\\d[\\d,]*\\s+bps/')).toBeVisible();

  // Ensure ffmpeg finishes cleanly
  const code = await ffmpeg.done;
  expect(code).toBe(0);

  // Stop + delete route (best-effort cleanup)
  await request.get(`${baseURL}/api/routes/${routeId}/stop`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  await request.delete(`${baseURL}/api/routes/${routeId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
});

