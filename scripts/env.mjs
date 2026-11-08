import { getLocalEnv, loadSupabaseConfig } from './lib/guard.mjs';
import { detail, fail, info, pass, section } from './lib/output.mjs';

section('Local Supabase environment');

try {
  const config = loadSupabaseConfig();
  if (!config.exists) {
    throw new Error(
      'supabase/config.toml is missing. Agent 1 owns this file; static checks still work.',
    );
  }

  const local = getLocalEnv();

  pass('Local Supabase is running.');
  info(`API URL:  ${local.apiUrl}`);
  info(`DB URL:   ${local.dbUrl}`);
  info(`Anon key: ${local.anonKey ? 'present (redacted)' : 'missing'}`);
  info(`Service role key: ${local.serviceRoleKey ? 'present (redacted)' : 'missing'}`);
  detail('Keys are read from local containers only; no remote fallback is used.');
} catch (error) {
  fail(error.message);
  process.exit(1);
}
