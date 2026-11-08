import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { detail, fail, info, pass, section, summarize } from './lib/output.mjs';

const REGISTER_PATH = path.join('docs', 'test-blockers.md');
const SCAN_DIRS = ['tests', path.join('supabase', 'tests')];
const SCAN_EXTENSIONS = new Set(['.ts', '.sql', '.mjs']);
const BLOCKER_ID = /BLK-\d{3}/g;
const SKIP_CALL = /\b(skip|todo)\s*\(/g;

function walk(directory) {
  if (!existsSync(directory)) return [];
  const files = [];
  for (const entry of readdirSync(directory)) {
    const fullPath = path.join(directory, entry);
    const stats = statSync(fullPath);
    if (stats.isDirectory()) files.push(...walk(fullPath));
    else if (SCAN_EXTENSIONS.has(path.extname(entry))) files.push(fullPath);
  }
  return files;
}

function main() {
  section('Blocked-rule register');

  if (!existsSync(REGISTER_PATH)) {
    fail(`${REGISTER_PATH} is missing. Every blocked rule must be tracked.`);
    return summarize(['blocked-rule register']);
  }

  const register = readFileSync(REGISTER_PATH, 'utf8');
  const registered = new Set(register.match(BLOCKER_ID) ?? []);
  if (registered.size === 0) {
    fail(`${REGISTER_PATH} contains no BLK-### entries.`);
    return summarize(['blocked-rule register']);
  }

  const files = SCAN_DIRS.flatMap((directory) => walk(directory));
  const failures = [];

  for (const file of files) {
    const contents = readFileSync(file, 'utf8');
    const relative = path.relative(process.cwd(), file);

    for (const match of contents.matchAll(SKIP_CALL)) {
      const window = contents.slice(match.index, match.index + 400);
      const blocker = window.match(BLOCKER_ID)?.[0];
      if (!blocker) {
        failures.push(
          `${relative}: skipped test near "${match[1]}(" must reference a BLK-### entry and reason.`,
        );
      }
    }

    for (const match of contents.matchAll(BLOCKER_ID)) {
      if (!registered.has(match[0])) {
        failures.push(
          `${relative}: references ${match[0]}, which is not in ${REGISTER_PATH}.`,
        );
      }
    }
  }

  for (const blocker of registered) {
    pass(`registered ${blocker}`);
  }
  info(`Scanned ${files.length} test file(s) for skip/todo markers.`);

  if (failures.length > 0) {
    detail('Blocked tests must not encode unapproved business rules.');
    return summarize(failures);
  }

  pass('No unregistered skips or blocker references found.');
  return 0;
}

process.exit(main());
