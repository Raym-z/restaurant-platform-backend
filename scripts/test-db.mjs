import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { assertLocalEnvironment, getLocalEnv } from './lib/guard.mjs';
import { runSupabase, runNodeScript } from './lib/cli.mjs';
import { startTestStack } from './start-test-stack.mjs';
import { prepareTestDatabase } from './prepare-test-db.mjs';
import { isMain } from './lib/entry.mjs';
import { detail, fail, info, pass, section, warn } from './lib/output.mjs';

export async function testDatabase({ noStart = false, noReset = false } = {}) {
  const root = process.cwd();
  assertLocalEnvironment({ root, requireConfig: true, requireRunning: false });

  if (!noStart) {
    startTestStack({ full: false });
  }
  const local = getLocalEnv();
  const migrationsDir = path.join(root, 'supabase', 'migrations');
  const hasMigrations =
    existsSync(migrationsDir) &&
    readdirSync(migrationsDir).some((name) => name.toLowerCase().endsWith('.sql'));

  if (!noReset) {
    if (!hasMigrations) {
      warn(
        'No schema migrations yet (Agent 1 owns them); skipping database reset and lint.',
      );
    } else {
      section('Resetting local database (migrations only, no seed)');
      const reset = runSupabase(['db', 'reset', '--no-seed']);
      if (reset.status !== 0) {
        throw new Error(
          'Database reset failed. Check the migration output above; Agent 1 owns schema migrations.',
        );
      }
      pass('Migrations applied on a clean database.');
    }
  } else {
    info('Skipping database reset (--no-reset).');
  }

  await prepareTestDatabase({ root });

  if (hasMigrations) {
    section('Linting database functions');
    const lint = runSupabase(['db', 'lint', '--fail-on', 'error']);
    if (lint.status !== 0) {
      throw new Error('Database lint failed.');
    }
    pass('Database lint passed.');
  } else {
    warn('No supabase/migrations directory yet; migration lint skipped.');
  }

  const testsDir = path.join(root, 'supabase', 'tests', 'database');
  if (!existsSync(testsDir)) {
    warn('No supabase/tests/database directory; pgTAP suite skipped.');
    return;
  }

  section('Running pgTAP database tests');
  const tests = runSupabase(['test', 'db']);
  if (tests.status !== 0) {
    throw new Error('pgTAP database tests failed.');
  }
  pass('pgTAP database tests passed.');

  section('Checking RLS coverage manifest against the database');
  const coverage = runNodeScript('scripts/verify-rls-coverage.mjs', ['--db'], {
    env: { TEST_DB_URL: local.dbUrl },
  });
  if (coverage.status !== 0) {
    throw new Error('RLS coverage check failed.');
  }
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  testDatabase({
    noStart: args.includes('--no-start'),
    noReset: args.includes('--no-reset'),
  }).catch((error) => {
    fail(error.message);
    if (process.platform === 'win32') {
      detail('Windows: run "npm run doctor" if Docker or local Supabase is unavailable.');
    }
    process.exit(1);
  });
}
