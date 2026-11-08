import { readdirSync, existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { assertLocalEnvironment } from './lib/guard.mjs';
import { isMain } from './lib/entry.mjs';
import { detail, info, pass, section } from './lib/output.mjs';

const { Client } = pg;

const SQL_DIRS = [
  'tests/sql/helpers',
  'tests/sql/factories',
  'tests/sql/scenarios',
];

function listSqlFiles(root) {
  const files = [];
  for (const relativeDir of SQL_DIRS) {
    const directory = path.join(root, relativeDir);
    if (!existsSync(directory)) continue;
    for (const name of readdirSync(directory)) {
      if (name.toLowerCase().endsWith('.sql')) {
        files.push(path.join(directory, name));
      }
    }
  }
  return files.sort((a, b) => a.localeCompare(b));
}

export async function prepareTestDatabase({ root = process.cwd() } = {}) {
  const { local } = assertLocalEnvironment({
    root,
    requireConfig: true,
    requireRunning: true,
  });

  section('Preparing test helper schema');
  const files = listSqlFiles(root);
  if (files.length === 0) {
    throw new Error('No test helper SQL files found under tests/sql/.');
  }

  const client = new Client({ connectionString: local.dbUrl });
  await client.connect();

  try {
    await client.query('create extension if not exists pgtap');
    await client.query('begin');
    await client.query('drop schema if exists tests cascade');
    await client.query('create schema tests');

    for (const file of files) {
      const relative = path.relative(root, file);
      process.stdout.write(`      applying ${relative}\n`);
      await client.query(readFileSync(file, 'utf8'));
    }

    await client.query('commit');
    pass(`Applied ${files.length} helper/factory/scenario file(s).`);
  } catch (error) {
    try {
      await client.query('rollback');
    } catch {
      // Ignore rollback failures; the original error is more useful.
    }
    throw new Error(`Failed to prepare test database: ${error.message}`);
  } finally {
    await client.end();
  }

  const verifier = new Client({ connectionString: local.dbUrl });
  await verifier.connect();
  let check;
  try {
    const result = await verifier.query(
      "select count(*)::int as count from information_schema.schemata where schema_name = 'tests'",
    );
    check = result.rows[0].count;
  } finally {
    await verifier.end();
  }

  if (check !== 1) {
    throw new Error('Test helper schema was not created.');
  }
  info('Test helper schema "tests" is ready.');
  detail('Helpers are recreated on every prepare; they are never migrations.');
}

if (isMain(import.meta.url)) {
  prepareTestDatabase().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
