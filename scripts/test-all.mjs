import { runNodeScript } from './lib/cli.mjs';
import { isMain } from './lib/entry.mjs';
import { detail, fail, info, pass, section } from './lib/output.mjs';

const STEPS = [
  ['Doctor', 'scripts/doctor.mjs', []],
  ['Static checks', 'scripts/run-static.mjs', []],
  ['Database tests', 'scripts/test-db.mjs', []],
  ['Integration/concurrency tests', 'scripts/test-integration.mjs', []],
  ['Edge tests', 'scripts/test-edge.mjs', []],
];

export function runAll() {
  for (const [label, script, args] of STEPS) {
    section(label);
    const result = runNodeScript(script, args);
    if (result.status !== 0) {
      fail(`${label} failed; stopping the complete suite.`);
      return result.status ?? 1;
    }
    pass(`${label} completed.`);
  }

  info('Complete local suite finished.');
  detail('Database tests use a clean reset without development seed data.');
  return 0;
}

if (isMain(import.meta.url)) {
  process.exit(runAll());
}
