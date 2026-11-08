import { assertLocalEnvironment, getLocalEnv } from './lib/guard.mjs';
import { isMain } from './lib/entry.mjs';
import { info, pass, section, warn } from './lib/output.mjs';
import { runSupabase } from './lib/cli.mjs';

const DB_SERVICES_TO_SKIP = ['studio', 'imgproxy', 'mailpit', 'logflare', 'vector'];

export function startTestStack({ full = false } = {}) {
  assertLocalEnvironment({ requireConfig: true, requireRunning: false });

  section(full ? 'Starting full local Supabase stack' : 'Starting local Supabase stack');

  const args = ['start'];
  if (!full) {
    args.push('-x', DB_SERVICES_TO_SKIP.join(','));
    info(`Skipping non-essential services: ${DB_SERVICES_TO_SKIP.join(', ')}`);
  }

  const result = runSupabase(args);
  if (result.status !== 0) {
    throw new Error(
      'Failed to start the local Supabase stack. Run "npm run doctor" for diagnostics.',
    );
  }

  const local = getLocalEnv();
  pass(`Local API ready: ${local.apiUrl}`);
  pass(`Local DB ready:  ${local.dbUrl}`);
  return local;
}

if (isMain(import.meta.url)) {
  try {
    startTestStack({ full: process.argv.includes('--full') });
  } catch (error) {
    warn(error.message);
    process.exit(1);
  }
}
