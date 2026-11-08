import pg from 'pg';

/**
 * Truncate all public tables as the local postgres role. This is a local-only
 * safety valve for concurrency suites, which must commit data to race correctly.
 *
 * Never call this against a remote database. The caller is responsible for
 * obtaining its connection through setup/db.ts, which enforces loopback hosts.
 */
export async function truncatePublicTables(client: pg.Client): Promise<void> {
  const result = await client.query<{ tablename: string }>(
    "select tablename from pg_tables where schemaname = 'public' order by tablename",
  );

  if (result.rowCount === 0) return;

  const tables = result.rows
    .map((row) => `"public"."${row.tablename.replaceAll('"', '""')}"`)
    .join(', ');

  await client.query(`truncate table ${tables} restart identity cascade`);
}

export async function closeQuietly(client: pg.Client | undefined): Promise<void> {
  if (!client) return;
  await client.end().catch(() => undefined);
}
