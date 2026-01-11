import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: 'inherit', ...opts });
    p.on('exit', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} ${args.join(' ')} exited with code ${code}`));
    });
  });
}

function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

const here = path.dirname(new URL(import.meta.url).pathname);
const webAppDir = path.resolve(here, '..');
const repoRoot = path.resolve(webAppDir, '..');
const distDir = path.join(webAppDir, 'dist');
const staticDir = path.join(repoRoot, 'priv', 'static');

const host = process.env.E2E_HOST || '127.0.0.1';
const port = process.env.E2E_PORT || process.env.PORT || '4000';

async function main() {
  // Build UI
  await run('npm', ['run', 'build'], { cwd: webAppDir });

  if (!fs.existsSync(distDir)) {
    throw new Error(`web_app/dist not found at ${distDir}`);
  }

  // Copy dist into Phoenix priv/static (served by HydraSrtWeb.Endpoint)
  fs.mkdirSync(staticDir, { recursive: true });
  copyDir(distDir, staticDir);

  // Start Phoenix server in MIX_ENV=test with E2E_UI toggle
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hydra_khepri_ui_e2e_'));
  fs.mkdirSync(dataDir, { recursive: true });
  const unitDbPath = path.join(dataDir, 'hydra_srt_ui_e2e.db');

  const env = {
    ...process.env,
    MIX_ENV: 'test',
    E2E_UI: 'true',
    E2E_HOST: host,
    E2E_PORT: String(port),
    PORT: String(port),
    DATABASE_DATA_DIR: dataDir,
    // Ensure the Phoenix server and any pre-start tasks (ecto.create/migrate) share the same DB.
    UNIT_DATABASE_PATH: unitDbPath,
  };

  // Ensure DB exists + migrations are applied (MIX_ENV=test server does not run mix test aliases).
  await run('mix', ['ecto.create', '--quiet'], { cwd: repoRoot, stdio: 'inherit', env });
  await run('mix', ['ecto.migrate', '--quiet'], { cwd: repoRoot, stdio: 'inherit', env });

  const server = spawn('mix', ['phx.server'], { cwd: repoRoot, stdio: 'inherit', env });

  const shutdown = () => {
    server.kill('SIGTERM');
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  server.on('exit', (code) => process.exit(code ?? 0));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

