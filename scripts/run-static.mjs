import { spawnSync } from 'node:child_process';
import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { runNodeBin, runNodeScript } from './lib/cli.mjs';
import { isMain } from './lib/entry.mjs';
import { fail, pass, section, summarize } from './lib/output.mjs';

const failures = [];

function step(label, fn) {
  section(label);
  try {
    const status = fn();
    if (status !== 0) {
      failures.push(label);
    }
  } catch (error) {
    fail(error.message);
    failures.push(label);
  }
}

function walk(directory) {
  const files = [];
  for (const entry of readdirSync(directory)) {
    const fullPath = path.join(directory, entry);
    const stats = statSync(fullPath);
    if (stats.isDirectory()) files.push(...walk(fullPath));
    else if (entry.endsWith('.mjs')) files.push(fullPath);
  }
  return files;
}

function syntaxCheck() {
  let status = 0;
  const scripts = walk(path.join(process.cwd(), 'scripts'));
  for (const script of scripts) {
    const result = spawnSync(process.execPath, ['--check', script], {
      encoding: 'utf8',
    });
    if (result.status !== 0) {
      fail(`Syntax error in ${path.relative(process.cwd(), script)}`);
      if (result.stderr) console.error(result.stderr);
      status = 1;
    }
  }
  if (status === 0) pass(`Syntax checked ${scripts.length} script(s).`);
  return status;
}

export function runStaticChecks() {
  step('Script syntax', syntaxCheck);

  step('Migration governance', () =>
    runNodeScript('scripts/verify-migrations.mjs').status,
  );

  step('Secret scan', () => runNodeScript('scripts/verify-secrets.mjs').status);

  step('Blocked-rule register', () =>
    runNodeScript('scripts/verify-blockers.mjs').status,
  );

  step('RLS coverage manifest (static)', () =>
    runNodeScript('scripts/verify-rls-coverage.mjs', ['--static']).status,
  );

  step('Contract path drift (static)', () =>
    runNodeScript('scripts/verify-contract-drift.mjs', ['--static']).status,
  );

  step('TypeScript typecheck', () =>
    runNodeBin('typescript', ['-p', 'tsconfig.test.json', '--noEmit'], {
      binName: 'tsc',
    }).status,
  );

  step('Contract tests', () =>
    runNodeBin(
      'vitest',
      ['run', 'tests/contract', '--passWithNoTests'],
      { binName: 'vitest' },
    ).status,
  );

  return summarize(failures);
}

if (isMain(import.meta.url)) {
  process.exit(runStaticChecks());
}
