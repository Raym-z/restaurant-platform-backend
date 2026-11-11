import { randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import { authenticateAs } from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

describe("DB-backed rate limiting", () => {
  it("allows exactly the configured attempts and returns retry metadata", async () => {
    const client = await createClient();
    clients.push(client);
    await authenticateAs(client, randomUUID(), "service_role");

    const bucket = `test-limit-${randomUUID()}`;
    const results: Array<{ allowed: boolean; retryAfterSeconds: number }> = [];

    for (let index = 0; index < 11; index += 1) {
      const result = await client.query<{
        result: { allowed: boolean; retryAfterSeconds: number };
      }>("select public.consume_rate_limit($1, $2) as result", [
        "waitlist_join_customer",
        bucket,
      ]);
      results.push(result.rows[0]!.result);
    }

    expect(results.slice(0, 10).every((entry) => entry.allowed)).toBe(true);
    expect(results[10]!.allowed).toBe(false);
    expect(results[10]!.retryAfterSeconds).toBeGreaterThan(0);
  });

  it("serializes concurrent consumption without over-allowing", async () => {
    const actors = await Promise.all(
      Array.from({ length: 12 }, async () => {
        const client = await createClient();
        clients.push(client);
        await authenticateAs(client, randomUUID(), "service_role");
        return client;
      }),
    );

    const bucket = `test-concurrent-${randomUUID()}`;
    const results = await Promise.all(
      actors.map((client) =>
        client.query<{
          result: { allowed: boolean };
        }>("select public.consume_rate_limit($1, $2) as result", [
          "waitlist_join_customer",
          bucket,
        ]),
      ),
    );
    const allowed = results.filter((row) => row.rows[0]!.result.allowed).length;

    expect(allowed).toBe(10);
  });

  it("cleans up buckets older than the retention interval", async () => {
    const client = await createClient();
    clients.push(client);

    const oldBucket = `test-retention-old-${randomUUID()}`;
    const currentBucket = `test-retention-current-${randomUUID()}`;

    await client.query(
      `insert into private.rate_limit_buckets
         (policy_key, bucket_key, window_start, count)
       values
         ('waitlist_join_customer', $1, now() - interval '2 days', 1),
         ('waitlist_join_customer', $2, date_trunc('hour', now()), 1)`,
      [oldBucket, currentBucket],
    );

    await authenticateAs(client, randomUUID(), "service_role");
    const deleted = await client.query<{ result: number }>(
      "select public.cleanup_rate_limit_buckets(60) as result",
    );
    expect(deleted.rows[0]!.result).toBeGreaterThanOrEqual(1);

    const oldRemaining = await client.query<{ count: string }>(
      `select count(*)::text as count
         from private.rate_limit_buckets
        where bucket_key = $1`,
      [oldBucket],
    );
    expect(Number(oldRemaining.rows[0]!.count)).toBe(0);

    const currentRemaining = await client.query<{ count: string }>(
      `select count(*)::text as count
         from private.rate_limit_buckets
        where bucket_key = $1`,
      [currentBucket],
    );
    expect(Number(currentRemaining.rows[0]!.count)).toBe(1);
  });

  it("seeds the guest and waitlist policies", async () => {
    const client = await createClient();
    clients.push(client);

    const result = await client.query<{ policy_key: string }>(
      `select policy_key
         from private.rate_limit_policies
        where policy_key in (
          'guest_resolve_ip',
          'guest_resolve_qr',
          'guest_reconnect_ip',
          'guest_session_ip',
          'guest_token',
          'waitlist_join_customer'
        )
        order by policy_key`,
    );

    expect(result.rows.map((row) => row.policy_key)).toEqual([
      "guest_reconnect_ip",
      "guest_resolve_ip",
      "guest_resolve_qr",
      "guest_session_ip",
      "guest_token",
      "waitlist_join_customer",
    ]);
  });
});
