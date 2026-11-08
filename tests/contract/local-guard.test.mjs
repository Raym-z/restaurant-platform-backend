import { afterEach, describe, expect, it } from 'vitest';
import {
  assertLoopbackDbUrl,
  assertLoopbackUrl,
  isLoopbackHost,
  loadSupabaseConfig,
  parseStatusEnv,
} from '../../scripts/lib/guard.mjs';

const savedEnv = {};

afterEach(() => {
  for (const [key, value] of Object.entries(savedEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
    delete savedEnv[key];
  }
});

function setEnv(key, value) {
  if (!(key in savedEnv)) savedEnv[key] = process.env[key];
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}

describe('local environment guard', () => {
  it('accepts only loopback hosts', () => {
    for (const host of ['localhost', '127.0.0.1', '::1', '[::1]']) {
      expect(isLoopbackHost(host)).toBe(true);
    }
    for (const host of ['example.com', '10.0.0.1', '192.168.1.10', '']) {
      expect(isLoopbackHost(host)).toBe(false);
    }
  });

  it('rejects non-local API and database URLs', () => {
    expect(() => assertLoopbackUrl('https://example.supabase.co', 'API')).toThrow();
    expect(() =>
      assertLoopbackDbUrl('postgresql://user:pass@db.example.com:5432/postgres'),
    ).toThrow();
    expect(() =>
      assertLoopbackDbUrl('postgresql://postgres:postgres@127.0.0.1:54322/postgres'),
    ).not.toThrow();
    expect(() => assertLoopbackDbUrl('https://127.0.0.1/db')).toThrow();
  });

  it('parses supabase status env output', () => {
    const parsed = parseStatusEnv(
      [
        'API_URL="http://127.0.0.1:54321"',
        "DB_URL='postgresql://postgres:postgres@127.0.0.1:54322/postgres'",
        'ANON_KEY=local-value',
      ].join('\n'),
    );
    expect(parsed.API_URL).toBe('http://127.0.0.1:54321');
    expect(parsed.DB_URL).toBe(
      'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
    );
    expect(parsed.ANON_KEY).toBe('local-value');
  });

  it('reads the committed Supabase configuration', () => {
    const config = loadSupabaseConfig();
    expect(config.exists).toBe(true);
    expect(config.apiPort).toBe(54321);
    expect(config.dbPort).toBe(54322);
  });

  it('recognises a remote environment override', async () => {
    const { assertLocalEnvironment } = await import('../../scripts/lib/guard.mjs');
    setEnv('SUPABASE_URL', 'https://example.supabase.co');
    expect(() => assertLocalEnvironment({ requireRunning: false })).toThrow(
      /not a local host|not local/i,
    );
    setEnv('SUPABASE_URL', undefined);
  });
});
