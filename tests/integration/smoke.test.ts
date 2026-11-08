import { describe, expect, it } from 'vitest';
import { createClient } from './setup/db.js';

describe('integration harness', () => {
  it('connects to the local database and executes a query', async () => {
    const client = await createClient();
    try {
      const result = await client.query<{ ok: number }>('select 1 as ok');
      expect(result.rows[0]?.ok).toBe(1);
    } finally {
      await client.end().catch(() => undefined);
    }
  });
});
