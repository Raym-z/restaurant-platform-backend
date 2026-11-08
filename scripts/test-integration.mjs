import { assertLocalEnvironment } from './lib/guard.mjs';
import { runNodeBin } from './lib/cli.mjs';
import { isMain } from './lib/entry.mjs';
import { detail, fail, info, pass, section } from './lib/output.mjs';

export function runIntegrationTests() {
  const { local } = assertLocalEnvironment({
    requireConfig: true,
    requireRunning: true,
  });

  section('Running Node integration and concurrency tests');
  info('Each concurrent actor uses its own database connection.');
  detail('Tests are expected to isolate fixtures and clean up in finally/teardown paths.');

  const result = runNodeBin(
    'vitest',
    ['run', 'tests/integration', '--passWithNoTests', '--reporter=verbose'],
    {
      binName: 'vitest',
      env: {
        TEST_DB_URL: local.dbUrl,
        SUPABASE_URL: local.apiUrl,
        SUPABASE_ANON_KEY: local.anonKey ?? '',
        SUPABASE_SERVICE_ROLE_KEY: local.serviceRoleKey ?? '',
      },
    },
  );

  if (result.status !== 0) {
    throw new Error('Integration/concurrency tests failed.');
  }
  pass('Integration/concurrency tests passed.');
}

if (isMain(import.meta.url)) {
  try {
    runIntegrationTests();
  } catch (error) {
    fail(error.message);
    process.exit(1);
  }
}
