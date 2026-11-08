import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { getLocalEnv } from './lib/guard.mjs';
import { detail, fail, info, pass, section, summarize, warn } from './lib/output.mjs';

const { Client } = pg;
const MANIFEST_PATH = path.join('tests', 'registry', 'rls-coverage.json');
const OPERATIONS = ['select', 'insert', 'update', 'delete'];
const TEST_ID = /^T-RLS-\d{3}$/;

function loadManifest() {
  if (!existsSync(MANIFEST_PATH)) {
    throw new Error(`${MANIFEST_PATH} is missing.`);
  }
  const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'));
  if (manifest.version !== 1 || typeof manifest.tables !== 'object' || manifest.tables === null) {
    throw new Error(`${MANIFEST_PATH} must contain { "version": 1, "tables": { ... } }.`);
  }
  return manifest;
}

function validateManifest(manifest) {
  const failures = [];
  for (const [table, operations] of Object.entries(manifest.tables)) {
    if (!table.startsWith('public.')) {
      failures.push(`Manifest key "${table}" must use the "public." prefix.`);
    }
    if (typeof operations !== 'object' || operations === null) {
      failures.push(`Manifest entry "${table}" must be an object of operations.`);
      continue;
    }
    let hasCoverage = false;
    for (const [operation, tests] of Object.entries(operations)) {
      if (!OPERATIONS.includes(operation)) {
        failures.push(`Manifest entry "${table}" has unsupported operation "${operation}".`);
        continue;
      }
      if (!Array.isArray(tests) || tests.length === 0) {
        failures.push(`Manifest entry "${table}.${operation}" must list at least one test ID.`);
        continue;
      }
      hasCoverage = true;
      for (const testId of tests) {
        if (!TEST_ID.test(testId)) {
          failures.push(`Manifest test ID "${testId}" must match T-RLS-###.`);
        }
      }
    }
    if (!hasCoverage) {
      failures.push(`Manifest entry "${table}" has no test coverage.`);
    }
  }
  return failures;
}

async function checkAgainstDatabase(manifest) {
  const failures = [];
  const warnings = [];
  const dbUrl = process.env.TEST_DB_URL ?? getLocalEnv().dbUrl;
  const client = new Client({ connectionString: dbUrl });
  await client.connect();

  let tables;
  let policies;
  try {
    tables = await client.query(`
      select n.nspname as schema_name, c.relname as table_name, c.relrowsecurity as rls_enabled
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
      order by 1, 2
    `);
    policies = await client.query(`
      select schemaname, tablename, policyname, cmd
      from pg_policies
      where schemaname = 'public'
      order by 1, 2, 3
    `);
  } finally {
    await client.end();
  }

  const manifestTables = new Set(Object.keys(manifest.tables));
  const liveTables = new Set(
    tables.rows.map((row) => `${row.schema_name}.${row.table_name}`),
  );

  if (manifestTables.size === 0) {
    warn('RLS coverage manifest is empty; enforcement is deferred until Agent 2 lands policies.');
    info(`Found ${liveTables.size} public table(s) and ${policies.rows.length} policy(ies).`);
    return { failures, warnings, deferred: true };
  }

  for (const row of tables.rows) {
    const key = `${row.schema_name}.${row.table_name}`;
    if (!row.rls_enabled) {
      failures.push(`${key}: RLS is not enabled.`);
    }
    if (!manifestTables.has(key)) {
      failures.push(`${key}: RLS-enabled table is missing from ${MANIFEST_PATH}.`);
    }
  }

  const policyTables = new Set(
    policies.rows.map((row) => `${row.schemaname}.${row.tablename}`),
  );
  for (const key of policyTables) {
    if (!manifestTables.has(key)) {
      failures.push(`${key}: policy exists but table is missing from the coverage manifest.`);
    }
  }

  for (const key of manifestTables) {
    if (!liveTables.has(key)) {
      warnings.push(`${key}: manifest entry has no matching live table (yet).`);
    }
  }

  pass(`${liveTables.size} public table(s) checked against the manifest.`);
  return { failures, warnings, deferred: false };
}

async function main() {
  section('RLS coverage manifest');
  const manifest = loadManifest();
  const manifestFailures = validateManifest(manifest);
  for (const failure of manifestFailures) fail(failure);

  if (process.argv.includes('--db')) {
    const { failures, warnings } = await checkAgainstDatabase(manifest);
    for (const warning of warnings) warn(warning);
    for (const failure of failures) fail(failure);
    if (failures.length > 0) {
      detail('Report missing RLS coverage to Agent 2; do not weaken policies to satisfy tests.');
      return summarize([...manifestFailures, ...failures], warnings);
    }
    pass('RLS coverage manifest matches the live database.');
    return summarize(manifestFailures, warnings);
  }

  if (manifestFailures.length > 0) {
    return summarize(manifestFailures);
  }
  pass('RLS coverage manifest is structurally valid.');
  info('Database comparison runs in the database CI job (verify-rls-coverage.mjs --db).');
  return 0;
}

main()
  .then((code) => process.exit(code))
  .catch((error) => {
    fail(error.message);
    process.exit(1);
  });
