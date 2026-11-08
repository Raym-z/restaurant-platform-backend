import pg from 'pg';
import { localDbUrl } from './env.js';

const { Client } = pg;

/**
 * Create a new, independent database connection. Concurrency tests must use one
 * connection per actor rather than sharing a pool.
 */
export async function createClient(): Promise<pg.Client> {
  const client = new Client({ connectionString: localDbUrl() });
  await client.connect();
  return client;
}

export async function withClient<T>(
  callback: (client: pg.Client) => Promise<T>,
): Promise<T> {
  const client = await createClient();
  try {
    return await callback(client);
  } finally {
    await client.end().catch(() => undefined);
  }
}
