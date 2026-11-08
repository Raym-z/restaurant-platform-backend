import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);

/**
 * Resolve the executable script for an npm package binary in a way that works
 * on Windows and POSIX without relying on shell execution.
 */
export function resolvePackageBin(packageName, binName = packageName) {
  const packageJsonPath = require.resolve(`${packageName}/package.json`);
  const packageJson = require(packageJsonPath);
  const relative =
    typeof packageJson.bin === 'string'
      ? packageJson.bin
      : packageJson.bin?.[binName];

  if (!relative) {
    throw new Error(
      `Could not find bin "${binName}" in package "${packageName}".`,
    );
  }

  return path.resolve(path.dirname(packageJsonPath), relative);
}

export function runNodeBin(packageName, args, options = {}) {
  const binPath = resolvePackageBin(packageName, options.binName ?? packageName);
  return runCommand(process.execPath, [binPath, ...args], options);
}

export function runNodeScript(scriptPath, args = [], options = {}) {
  return runCommand(process.execPath, [scriptPath, ...args], options);
}

export function runCommand(command, args = [], options = {}) {
  const capture = options.capture === true;
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? process.cwd(),
    env: { ...process.env, ...(options.env ?? {}) },
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    shell: false,
    timeout: options.timeout ?? 0,
  });

  if (options.throwOnError && (result.error || result.status !== 0)) {
    const detail = result.error?.message ?? result.stderr ?? '';
    throw new Error(
      `Command failed: ${command} ${args.join(' ')}${detail ? `\n${detail}` : ''}`,
    );
  }

  return result;
}

export function captureCommand(command, args = [], options = {}) {
  const result = runCommand(command, args, { ...options, capture: true });
  return {
    status: result.status,
    stdout: (result.stdout ?? '').trim(),
    stderr: (result.stderr ?? '').trim(),
    error: result.error,
    ok: !result.error && result.status === 0,
  };
}

export function runSupabase(args, options = {}) {
  return runNodeBin('supabase', args, { ...options, binName: 'supabase' });
}

export function captureSupabase(args, options = {}) {
  const result = runNodeBin('supabase', args, {
    ...options,
    binName: 'supabase',
    capture: true,
  });
  return {
    status: result.status,
    stdout: (result.stdout ?? '').trim(),
    stderr: (result.stderr ?? '').trim(),
    error: result.error,
    ok: !result.error && result.status === 0,
  };
}
