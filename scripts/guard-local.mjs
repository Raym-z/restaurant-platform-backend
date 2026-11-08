import { assertLocalEnvironment, loadSupabaseConfig } from './lib/guard.mjs';
import { detail, fail, info, pass, section, warn } from './lib/output.mjs';

const args = process.argv.slice(2);
const requireConfig = !args.includes('--no-config');
const requireRunning = args.includes('--require-running');

section('Local environment guard');

try {
  const { config, local } = assertLocalEnvironment({
    requireConfig,
    requireRunning,
    processArgs: args,
  });

  if (config.exists) {
    pass(`Supabase config found: ${config.path}`);
    info(
      `project_id=${config.projectId ?? '<unset>'} api_port=${config.apiPort} db_port=${config.dbPort}`,
    );
    if (!config.dbMajorVersion) {
      warn('Postgres major version is not pinned in config.toml.');
    }
  } else {
    warn('supabase/config.toml is absent; database tests are blocked on Agent 1.');
  }

  if (local) {
    pass(`Local API: ${local.apiUrl}`);
    pass(`Local DB:  ${local.dbUrl}`);
  } else {
    info('Local Supabase is not required for static checks.');
  }

  if (requireRunning && !local) {
    throw new Error('Local Supabase stack is not running.');
  }
} catch (error) {
  fail(error.message);
  if (process.platform === 'win32') {
    detail('Windows: start Docker Desktop and run "npm run doctor" for diagnostics.');
  }
  process.exit(1);
}

// Re-read for a friendly summary even when --no-config was used.
const config = loadSupabaseConfig();
if (config.exists && config.seedEnabled === 'true') {
  detail(
    'Seed is enabled for development; test runs use "supabase db reset --no-seed".',
  );
}
