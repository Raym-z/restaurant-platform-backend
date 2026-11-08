import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { isMain } from './lib/entry.mjs';
import { startTestStack } from './start-test-stack.mjs';
import { detail, fail, info, pass, section } from './lib/output.mjs';

export function hasEdgeFunctions(root = process.cwd()) {
  const directory = path.join(root, 'supabase', 'functions');
  if (!existsSync(directory)) return false;
  return readdirSync(directory).some((entry) => {
    if (entry.startsWith('_')) return false;
    return statSync(path.join(directory, entry)).isDirectory();
  });
}

function hasEdgeTests(root = process.cwd()) {
  const directory = path.join(root, 'tests', 'edge');
  if (!existsSync(directory)) return false;
  return readdirSync(directory).some((entry) => entry.endsWith('.test.ts'));
}

export function runEdgeTests() {
  const root = process.cwd();
  if (!hasEdgeFunctions(root)) {
    info('No Edge Functions yet; Agent 2 owns them. Edge tests skipped.');
    return 0;
  }

  const denoVersion = spawnSync('deno', ['--version'], { encoding: 'utf8' });
  if (denoVersion.error || denoVersion.status !== 0) {
    fail('Deno is not installed; Edge unit/integration tests require Deno.');
    detail('Install Deno or run the static/database suites only.');
    return 1;
  }

  if (!hasEdgeTests(root)) {
    info('Edge Functions exist but no Edge tests are implemented yet.');
    detail('Add tests under tests/edge/*.test.ts once Agent 2 publishes contracts.');
    return 0;
  }

  startTestStack({ full: true });

  section('Running Edge Function tests');
  const result = spawnSync('deno', ['test', '--allow-all', path.join('tests', 'edge')], {
    stdio: 'inherit',
    shell: false,
  });
  if (result.status !== 0) {
    fail('Edge Function tests failed.');
    return result.status ?? 1;
  }
  pass('Edge Function tests passed.');
  return 0;
}

if (isMain(import.meta.url)) {
  process.exit(runEdgeTests());
}
