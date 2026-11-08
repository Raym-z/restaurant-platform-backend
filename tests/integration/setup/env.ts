const LOOPBACK_HOSTS = new Set([
  'localhost',
  '127.0.0.1',
  '::1',
  '[::1]',
  '0:0:0:0:0:0:0:1',
]);

/**
 * Resolve the local test database URL. Fails closed: never fall back to a
 * remote database or credential.
 */
export function localDbUrl(): string {
  const raw =
    process.env.TEST_DB_URL ??
    process.env.SUPABASE_DB_URL ??
    'postgresql://postgres:postgres@127.0.0.1:54322/postgres';

  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`TEST_DB_URL is not a valid URL: ${raw}`);
  }

  if (!['postgres:', 'postgresql:'].includes(parsed.protocol)) {
    throw new Error('TEST_DB_URL must use the postgres/postgresql protocol.');
  }

  if (!LOOPBACK_HOSTS.has(parsed.hostname.toLowerCase())) {
    throw new Error(
      `Refusing to run integration tests against non-local host "${parsed.hostname}".`,
    );
  }

  return raw;
}
