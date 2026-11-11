import { randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import { authenticateAs, createOrgFixture, expectPgError } from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

describe("branch limit concurrency", () => {
  it("prevents concurrent branch creation from exceeding the plan limit", async () => {
    const admin = await createClient();
    const first = await createClient();
    const second = await createClient();
    clients.push(admin, first, second);

    const fixture = await createOrgFixture(admin, {
      branchCount: 0,
      branchLimit: 1,
    });

    await authenticateAs(first, fixture.ownerAuthUserId);
    await authenticateAs(second, fixture.ownerAuthUserId);

    const firstCall = first.query(
      "select public.create_branch($1, $2, $3, null, null, $4) as result",
      [
        fixture.organizationId,
        "Concurrent A",
        "Asia/Jakarta",
        `branch-a-${randomUUID()}`,
      ],
    );
    const secondCall = second.query(
      "select public.create_branch($1, $2, $3, null, null, $4) as result",
      [
        fixture.organizationId,
        "Concurrent B",
        "Asia/Jakarta",
        `branch-b-${randomUUID()}`,
      ],
    );

    const results = await Promise.allSettled([firstCall, secondCall]);
    const fulfilled = results.filter((result) => result.status === "fulfilled");
    const rejected = results.filter((result) => result.status === "rejected");

    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);

    const reason = rejected[0] as PromiseRejectedResult;
    expect(String(reason.reason)).toContain("BRANCH_LIMIT_REACHED");

    const count = await admin.query<{ count: string }>(
      "select count(*)::text as count from public.branches where organization_id = $1 and status = 'active'",
      [fixture.organizationId],
    );

    expect(Number(count.rows[0]!.count)).toBe(1);
  });

  it("returns IDEMPOTENCY_CONFLICT for a reused key with different data", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const fixture = await createOrgFixture(admin, {
      branchCount: 0,
      branchLimit: 10,
    });
    await authenticateAs(owner, fixture.ownerAuthUserId);

    const key = `idem-${randomUUID()}`;

    await owner.query(
      "select public.create_branch($1, $2, $3, null, null, $4) as result",
      [fixture.organizationId, "First", "Asia/Jakarta", key],
    );

    const fingerprint = await admin.query<{ length: number }>(
      `select length(request_fingerprint)::int as length
         from private.idempotency_keys
        where operation = 'create_branch'
          and idempotency_key = $1`,
      [key],
    );
    expect(fingerprint.rows[0]!.length).toBe(64);

    const replay = await owner.query<{ result: Record<string, unknown> }>(
      "select public.create_branch($1, $2, $3, null, null, $4) as result",
      [fixture.organizationId, "  First  ", " Asia/Jakarta ", key],
    );
    expect(replay.rows[0]!.result.branchId).toBeDefined();

    await expectPgError(
      owner.query(
        "select public.create_branch($1, $2, $3, null, null, $4) as result",
        [fixture.organizationId, "Different", "Asia/Jakarta", key],
      ),
      "IDEMPOTENCY_CONFLICT",
    );
  });
});
