import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { captureSupabase } from './cli.mjs';

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]', '0:0:0:0:0:0:0:1']);

const LOCAL_ENV_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_DB_URL',
  'DATABASE_URL',
  'PGHOST',
];

const REMOTE_FLAGS = ['--remote', '--linked', '--project-ref'];

export function isLoopbackHost(host) {
  if (!host) return false;
  return LOOPBACK_HOSTS.has(String(host).trim().toLowerCase());
}

export function assertLoopbackUrl(rawUrl, label) {
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error(`${label} is not a valid URL: ${rawUrl}`);
  }
  if (!isLoopbackHost(parsed.hostname)) {
    throw new Error(
      `${label} points at "${parsed.hostname}", which is not a local host. ` +
        'This test tooling only operates against 127.0.0.1/localhost/::1.',
    );
  }
  return parsed;
}

export function assertLoopbackDbUrl(rawUrl, label = 'database URL') {
  const parsed = assertLoopbackUrl(rawUrl, label);
  if (!['postgres:', 'postgresql:'].includes(parsed.protocol)) {
    throw new Error(`${label} must use the postgres/postgresql protocol.`);
  }
  return parsed;
}

function sectionValue(contents, section, key) {
  const escapedSection = section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const sectionMatch = contents.match(
    new RegExp(`(^|\\n)\\[${escapedSection}\\]([\\s\\S]*?)(?=\\n\\[|$)`),
  );
  if (!sectionMatch) return undefined;
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const keyMatch = sectionMatch[2].match(
    new RegExp(`^\\s*${escapedKey}\\s*=\\s*(.+?)\\s*$`, 'm'),
  );
  if (!keyMatch) return undefined;
  return keyMatch[1].replace(/^["']|["']$/g, '');
}

export function loadSupabaseConfig(root = process.cwd()) {
  const configPath = path.join(root, 'supabase', 'config.toml');
  if (!existsSync(configPath)) {
    return { exists: false, path: configPath };
  }

  const contents = readFileSync(configPath, 'utf8');
  const projectId = contents.match(/^\s*project_id\s*=\s*["']([^"']+)["']/m)?.[1];
  const apiPort = Number(sectionValue(contents, 'api', 'port') ?? 54321);
  const dbPort = Number(sectionValue(contents, 'db', 'port') ?? 54322);
  const shadowPort = Number(sectionValue(contents, 'db', 'shadow_port') ?? 54320);
  const dbMajorVersion = sectionValue(contents, 'db', 'major_version');
  const seedEnabled = sectionValue(contents, 'db.seed', 'enabled');

  return {
    exists: true,
    path: configPath,
    projectId,
    apiPort,
    dbPort,
    shadowPort,
    dbMajorVersion,
    seedEnabled,
    contents,
  };
}

export function parseStatusEnv(rawOutput) {
  const result = {};
  for (const line of String(rawOutput ?? '').split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    result[match[1]] = value;
  }
  return result;
}

export function getLocalEnv({ allowStopped = false, timeout = 60000 } = {}) {
  const result = captureSupabase(['status', '-o', 'env'], { timeout });
  if (!result.ok) {
    if (allowStopped) return null;
    throw new Error(
      'Local Supabase is not running. Start it with "npm run test:db" or ' +
        '"npm run test:db:start" before running database-dependent tests.',
    );
  }

  const raw = parseStatusEnv(`${result.stdout}\n${result.stderr}`);
  const apiUrl = raw.API_URL;
  const dbUrl = raw.DB_URL;

  if (!apiUrl || !dbUrl) {
    throw new Error(
      'Could not read local Supabase API/database URLs from "supabase status -o env".',
    );
  }

  assertLoopbackUrl(apiUrl, 'Local Supabase API URL');
  assertLoopbackDbUrl(dbUrl, 'Local Supabase database URL');

  return {
    apiUrl,
    dbUrl,
    anonKey: raw.ANON_KEY,
    serviceRoleKey: raw.SERVICE_ROLE_KEY,
    jwtSecret: raw.JWT_SECRET,
    studioUrl: raw.STUDIO_URL,
    raw,
  };
}

function rejectRemoteFlags(processArgs) {
  for (const flag of REMOTE_FLAGS) {
    if (processArgs.some((arg) => arg === flag || arg.startsWith(`${flag}=`))) {
      throw new Error(
        `Refusing to run with remote flag "${flag}". Test tooling must target local Supabase only.`,
      );
    }
  }
}

function rejectRemoteEnvironment() {
  for (const key of LOCAL_ENV_KEYS) {
    const value = process.env[key];
    if (!value) continue;

    if (key === 'PGHOST') {
      if (!isLoopbackHost(value)) {
        throw new Error(
          `Environment variable ${key} points at "${value}", which is not local. ` +
            'Test tooling never falls back to remote credentials.',
        );
      }
      continue;
    }

    assertLoopbackUrl(value, `Environment variable ${key}`);
  }
}

export function assertLocalEnvironment({
  root = process.cwd(),
  requireConfig = true,
  requireRunning = false,
  processArgs = process.argv.slice(2),
} = {}) {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Refusing to run test tooling with NODE_ENV=production.');
  }

  if (process.env.CI === 'true' && process.env.GITHUB_ACTIONS === 'true') {
    // CI is expected to run the same local stack inside the runner. Continue,
    // but the runtime checks below still apply.
  }

  rejectRemoteFlags(processArgs);
  rejectRemoteEnvironment();

  const config = loadSupabaseConfig(root);
  if (requireConfig && !config.exists) {
    throw new Error(
      `Supabase configuration not found at ${path.relative(root, config.path)}. ` +
        'Agent 1 owns supabase/config.toml; database tests stay blocked until it exists. ' +
        'Static checks ("npm run test:static") do not require it.',
    );
  }

  const local = requireRunning ? getLocalEnv() : null;
  return { config, local };
}
