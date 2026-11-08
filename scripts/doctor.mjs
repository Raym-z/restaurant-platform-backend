import { statfsSync } from 'node:fs';
import net from 'node:net';
import { captureCommand, captureSupabase } from './lib/cli.mjs';
import { getLocalEnv, loadSupabaseConfig } from './lib/guard.mjs';
import {
  detail,
  fail,
  info,
  pass,
  section,
  summarize,
  warn,
} from './lib/output.mjs';

const failures = [];
const warnings = [];
const isWindows = process.platform === 'win32';

function check(label, fn) {
  try {
    const result = fn();
    if (result === false) return false;
    pass(label);
    return true;
  } catch (error) {
    fail(`${label}: ${error.message}`);
    failures.push(label);
    return false;
  }
}

function tryCapture(command, args, timeout = 15000) {
  return captureCommand(command, args, { timeout });
}

function portIsOpen(port, host = '127.0.0.1', timeout = 500) {
  return new Promise((resolve) => {
    const socket = net.connect({ port, host });
    const done = (open) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(open);
    };
    socket.setTimeout(timeout);
    socket.once('connect', () => done(true));
    socket.once('timeout', () => done(false));
    socket.once('error', () => done(false));
  });
}

section('Restaurant Platform backend doctor');
info(`Platform: ${process.platform} ${process.arch}`);
info(`Node: ${process.version}`);

if (isWindows) {
  detail('Windows detected. Docker Desktop must be running before database tests.');
}

// Node major version
const nodeMajor = Number(process.versions.node.split('.')[0]);
if (nodeMajor >= 24) {
  pass(`Node major version ${nodeMajor} satisfies the >=24 requirement.`);
} else {
  fail(`Node ${nodeMajor} is too old; use Node 24 (see .nvmrc).`);
  failures.push('Node version');
}

// Docker CLI
const dockerVersion = tryCapture('docker', ['--version']);
if (dockerVersion.ok) {
  pass(`Docker CLI: ${dockerVersion.stdout}`);
} else {
  fail('Docker CLI is not available.');
  if (isWindows) {
    detail('Install Docker Desktop for Windows with the WSL 2 backend, then reopen the terminal.');
  }
  failures.push('Docker CLI');
}

// Docker daemon
let dockerReady = false;
if (dockerVersion.ok) {
  const dockerInfo = tryCapture('docker', ['info', '--format', '{{.ServerVersion}}'], 20000);
  if (dockerInfo.ok && dockerInfo.stdout) {
    dockerReady = true;
    pass(`Docker daemon is reachable (engine ${dockerInfo.stdout}).`);
  } else {
    fail('Docker daemon is not reachable.');
    if (/500 Internal Server Error/i.test(dockerInfo.stderr ?? '')) {
      detail(
        'Docker Desktop is running but its Linux engine is unhealthy. This is often caused by WSL 2 / virtualization being unavailable.',
      );
    }
    detail(
      isWindows
        ? 'Start Docker Desktop and wait until the status shows "Engine running".'
        : 'Start the Docker daemon (for example: sudo systemctl start docker).',
    );
    detail('Then re-run: npm run doctor');
    failures.push('Docker daemon');
  }
}

if (dockerVersion.ok) {
  const context = tryCapture('docker', ['context', 'show']);
  if (context.ok) {
    if (context.stdout === 'desktop-linux' || !isWindows) {
      pass(`Docker context: ${context.stdout}`);
    } else {
      warn(
        `Docker context is "${context.stdout}". For Docker Desktop, use "docker context use desktop-linux".`,
      );
      warnings.push('Docker context');
    }
  }
}

if (isWindows && dockerVersion.ok) {
  const wsl = tryCapture('wsl', ['--status']);
  const wslOutput = `${wsl.stdout ?? ''}\n${wsl.stderr ?? ''}`
    .replaceAll('\u0000', '')
    .replace(/\s+/g, ' ')
    .trim();

  if (/not supported|not installed|Virtual Machine Platform|Please enable/i.test(wslOutput)) {
    fail('WSL 2 / Virtual Machine Platform is not available.');
    detail('Docker Desktop requires the WSL 2 backend on this machine.');
    detail('Enable the "Virtual Machine Platform" Windows feature, ensure virtualization is enabled in BIOS/UEFI, then run:');
    detail('  wsl --install --no-distribution');
    detail('Restart Windows and start Docker Desktop again.');
    failures.push('WSL 2');
  } else if (wsl.ok) {
    pass('WSL 2 is available.');
  } else {
    warn('WSL status could not be read. If Docker Desktop uses the WSL 2 backend, run "wsl --update".');
    warnings.push('WSL');
  }
}

// Supabase CLI
const supabaseVersion = captureSupabase(['--version'], { timeout: 30000 });
if (supabaseVersion.ok) {
  pass(`Supabase CLI: ${supabaseVersion.stdout || supabaseVersion.stderr}`);
} else {
  fail('Pinned Supabase CLI could not be executed.');
  if (supabaseVersion.stderr) detail(supabaseVersion.stderr.split('\n')[0]);
  failures.push('Supabase CLI');
}

// Config
const config = loadSupabaseConfig();
if (config.exists) {
  pass(`supabase/config.toml found (project_id=${config.projectId ?? '<unset>'}).`);
  info(
    `Ports: api=${config.apiPort} db=${config.dbPort} shadow=${config.shadowPort}` +
      `${config.dbMajorVersion ? `; Postgres major=${config.dbMajorVersion}` : ''}`,
  );
  if (!config.dbMajorVersion) {
    warn('Postgres major version is not pinned; database tests should match production.');
    warnings.push('Postgres version pin');
  }
} else {
  warn('supabase/config.toml is missing. Agent 1 owns it; database tests stay blocked.');
  warnings.push('Supabase config');
}

// Local stack
const local = getLocalEnv({ allowStopped: true, timeout: 30000 });
if (local) {
  pass('Local Supabase stack is running.');
  info(`API: ${local.apiUrl}`);
  info(`DB:  ${local.dbUrl}`);
} else {
  info('Local Supabase stack is not running (static checks do not need it).');
}

// Ports (only warn when not obviously owned by the running local stack)
const ports = [
  ['API', config.apiPort ?? 54321],
  ['DB', config.dbPort ?? 54322],
  ['shadow DB', config.shadowPort ?? 54320],
];
for (const [label, port] of ports) {
  const open = await portIsOpen(port);
  if (!open) {
    info(`Port ${port} (${label}) is free.`);
  } else if (local) {
    info(`Port ${port} (${label}) is in use by the running local stack.`);
  } else {
    warn(`Port ${port} (${label}) is already in use by another process.`);
    warnings.push(`Port ${port}`);
    if (isWindows) {
      detail(`Inspect the owner with: Get-NetTCPConnection -LocalPort ${port}`);
    }
  }
}

// Disk space
try {
  const stats = statfsSync(process.cwd());
  const freeGb = (stats.bavail * stats.bsize) / 1024 ** 3;
  if (freeGb < 5) {
    warn(`Only ${freeGb.toFixed(1)} GB free disk space; Supabase images need room.`);
    warnings.push('Disk space');
  } else {
    pass(`Free disk space: ${freeGb.toFixed(1)} GB.`);
  }
} catch {
  info('Disk space could not be determined on this platform.');
}

if (!dockerReady) {
  detail('');
  detail('Static-only mode is available without Docker: npm run test:static');
}

const exitCode = summarize(failures, warnings);
if (exitCode !== 0) {
  detail('');
  detail('Database tests are blocked until the critical items above are resolved.');
}
process.exit(exitCode);
