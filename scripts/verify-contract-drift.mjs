import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { captureSupabase } from './lib/cli.mjs';
import { detail, fail, info, pass, section, summarize, warn } from './lib/output.mjs';

const DEFAULT_TYPES_PATH = path.join('src', 'types', 'database.generated.ts');
const CONTRACTS_DIR = path.join('src', 'contracts');

function normalize(value) {
  return value.replace(/\r\n/g, '\n').trim();
}

function main() {
  section('Contract and generated-type drift');

  const typesPath = process.env.CONTRACT_TYPES_PATH ?? DEFAULT_TYPES_PATH;
  const staticMode = process.argv.includes('--static');

  if (!existsSync(CONTRACTS_DIR)) {
    info(`No shared contracts directory yet (${CONTRACTS_DIR}); Agent 2 owns it.`);
  }

  if (!existsSync(typesPath)) {
    info(`No generated database types yet (${typesPath}); drift check deferred.`);
    return 0;
  }

  const committed = readFileSync(typesPath, 'utf8');
  if (normalize(committed).length === 0) {
    fail(`${typesPath} is empty.`);
    return summarize(['generated types']);
  }

  if (staticMode) {
    pass(`${typesPath} exists and is non-empty (static check).`);
    info('The database CI job regenerates types and compares them.');
    return 0;
  }

  const generated = captureSupabase(['gen', 'types', 'typescript', '--local'], {
    timeout: 120000,
  });
  if (!generated.ok) {
    fail('Could not generate types from the local database. Is the stack running?');
    return summarize(['generated types']);
  }

  if (normalize(generated.stdout) !== normalize(committed)) {
    fail(`${typesPath} is out of date. Regenerate it from the local database.`);
    detail('Generated types are owned by Agent 2; report the drift instead of editing its contracts.');
    return summarize(['generated types drift']);
  }

  pass('Generated database types match the local schema.');
  if (!existsSync(CONTRACTS_DIR)) {
    warn('Shared contracts directory is still absent.');
  }
  return 0;
}

process.exit(main());
