import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { captureCommand } from './lib/cli.mjs';
import { analyzeSql } from './lib/sql-scan.mjs';
import {
  detail,
  fail,
  info,
  pass,
  section,
  summarize,
  warn,
} from './lib/output.mjs';

const MIGRATIONS_DIR = path.join('supabase', 'migrations');
const FILENAME_PATTERN = /^(\d{14})_[a-z0-9_]+\.sql$/;
const APPROVAL_MARKER = /approved-destructive-change/i;

const failures = [];
const warnings = [];

function git(args) {
  return captureCommand('git', args, { timeout: 30000 });
}

function resolveBaseRef() {
  const candidates = [];
  if (process.env.GITHUB_BASE_REF) candidates.push(`origin/${process.env.GITHUB_BASE_REF}`);
  candidates.push('origin/main', 'main');
  for (const candidate of candidates) {
    const result = git(['rev-parse', '--verify', '--quiet', `${candidate}^{commit}`]);
    if (result.ok) return candidate;
  }
  return null;
}

function listMigrations(root) {
  const directory = path.join(root, MIGRATIONS_DIR);
  if (!existsSync(directory)) return [];
  return readdirSync(directory)
    .filter((name) => name.endsWith('.sql'))
    .sort((a, b) => a.localeCompare(b))
    .map((name) => ({ name, path: path.join(directory, name) }));
}

function checkNames(migrations) {
  const seenTimestamps = new Map();
  for (const migration of migrations) {
    const match = migration.name.match(FILENAME_PATTERN);
    if (!match) {
      failures.push(
        `Invalid migration filename "${migration.name}". Expected YYYYMMDDHHMMSS_description.sql with lowercase snake_case.`,
      );
      continue;
    }
    const timestamp = match[1];
    if (seenTimestamps.has(timestamp)) {
      failures.push(
        `Duplicate migration timestamp ${timestamp}: "${seenTimestamps.get(timestamp)}" and "${migration.name}".`,
      );
    } else {
      seenTimestamps.set(timestamp, migration.name);
    }
  }

  const timestamps = migrations
    .map((migration) => migration.name.match(FILENAME_PATTERN)?.[1])
    .filter(Boolean);
  for (let index = 1; index < timestamps.length; index += 1) {
    if (timestamps[index] < timestamps[index - 1]) {
      failures.push(
        `Migration order is not strictly increasing around "${migrations[index].name}".`,
      );
    }
  }

  if (migrations.length > 0) {
    pass(`${migrations.length} migration file(s) follow the naming convention.`);
  }
}

function checkImmutability(baseRef, root) {
  if (!baseRef) {
    warn('No base ref (origin/main or main) available; migration immutability check skipped.');
    warnings.push('migration immutability');
    return;
  }

  const relativeDir = MIGRATIONS_DIR.replaceAll(path.sep, '/');
  const diff = git(['diff', '--name-status', baseRef, '--', relativeDir]);
  if (!diff.ok) {
    failures.push(`Could not diff migrations against ${baseRef}.`);
    return;
  }
  if (!diff.stdout) {
    pass('No migration changes relative to the base ref.');
    return;
  }

  let changed = 0;
  for (const line of diff.stdout.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const [status, ...paths] = line.split('\t');
    const code = status[0];
    if (code === 'A') {
      changed += 1;
      continue;
    }
    failures.push(
      `Applied migration must not be modified/deleted (status ${status}): ${paths.join(' -> ')}. Create a new migration instead.`,
    );
  }
  if (changed > 0) pass(`${changed} new migration(s) added relative to ${baseRef}.`);
  void root;
}

function readBaseMigrationNames(baseRef) {
  if (!baseRef) return new Set();
  const relativeDir = MIGRATIONS_DIR.replaceAll(path.sep, '/');
  const result = git(['ls-tree', '-r', '--name-only', baseRef, '--', relativeDir]);
  if (!result.ok) return new Set();
  return new Set(
    result.stdout
      .split(/\r?\n/)
      .filter(Boolean)
      .map((file) => path.basename(file)),
  );
}

function checkDestructiveAndSecurity(migrations, baseRef) {
  const baseNames = readBaseMigrationNames(baseRef);
  const newMigrations = migrations.filter(
    (migration) => !baseNames.has(migration.name) || !baseRef,
  );

  if (newMigrations.length === 0) {
    pass('No new migration SQL to scan.');
    return;
  }

  for (const migration of newMigrations) {
    const relative = path.relative(process.cwd(), migration.path);
    const sql = readFileSync(migration.path, 'utf8');
    const approved = APPROVAL_MARKER.test(sql);
    const analysis = analyzeSql(sql);

    if (!approved) {
      for (const finding of analysis.destructive) {
        failures.push(
          `${relative}:${finding.line}: ${finding.rule} requires "-- approved-destructive-change: <reference>" and review.`,
        );
      }
    }

    for (const finding of analysis.security) {
      const message =
        finding.rule === 'PRIVATE GRANT'
          ? finding.message
          : finding.rule === 'DISABLE RLS'
            ? 'DISABLE ROW LEVEL SECURITY is not permitted.'
            : finding.rule === 'SECURITY DEFINER'
              ? 'SECURITY DEFINER function must set an explicit search_path.'
              : finding.rule;
      failures.push(`${relative}:${finding.line}: ${message}`);
    }
  }

  if (newMigrations.length > 0) {
    pass(`Scanned ${newMigrations.length} new migration file(s) for destructive/security risks.`);
  }
}

function main() {
  section('Migration governance');
  const root = process.cwd();
  const migrations = listMigrations(root);
  const baseRef = resolveBaseRef();

  if (migrations.length === 0) {
    info('No migrations yet. Agent 1 owns schema migrations; nothing to validate.');
    return summarize(failures, warnings);
  }

  info(`Base ref: ${baseRef ?? '<none>'}`);
  checkNames(migrations);
  checkImmutability(baseRef, root);
  checkDestructiveAndSecurity(migrations, baseRef);

  if (failures.length > 0) {
    detail('Agent 3 never edits migrations; report issues to Agent 1 (schema) or Agent 2 (RLS/RPC services).');
  }

  return summarize(failures, warnings);
}

process.exit(main());
