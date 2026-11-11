import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  addStaff,
  authenticateAs,
  createCustomer,
  createOrgFixture,
  createTable,
  expectPgError,
} from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

const tokenHash = (): string => randomBytes(32).toString("hex");

describe("waitlist concurrency and rate limiting", () => {
  it("allows only one of two concurrent cancellations", async () => {
    const admin = await createClient();
    const first = await createClient();
    const second = await createClient();
    clients.push(admin, first, second);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const customer = await createCustomer(admin);
    const branchId = fixture.branchIds[0]!;

    await authenticateAs(first, customer.authUserId);
    const joined = await first.query<{ result: Record<string, unknown> }>(
      "select public.join_waitlist($1, $2, $3, $4, null, null, null) as result",
      [branchId, 2, "Customer", "+628123456789"],
    );
    const entryId = String(joined.rows[0]!.result.entryId);

    await authenticateAs(first, customer.authUserId);
    await authenticateAs(second, customer.authUserId);

    const results = await Promise.allSettled([
      first.query("select public.cancel_waitlist_entry($1, $2) as result", [
        entryId,
        "first",
      ]),
      second.query("select public.cancel_waitlist_entry($1, $2) as result", [
        entryId,
        "second",
      ]),
    ]);

    expect(
      results.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    expect(rejected).toBeDefined();
    expect(String((rejected as PromiseRejectedResult).reason)).toContain(
      "WAITLIST_INVALID_STATUS",
    );
  });

  it("rate-limits a customer joining many branches", async () => {
    const admin = await createClient();
    const customerClient = await createClient();
    clients.push(admin, customerClient);

    const fixture = await createOrgFixture(admin, {
      branchCount: 11,
      branchLimit: 20,
    });
    const customer = await createCustomer(admin);
    await authenticateAs(customerClient, customer.authUserId);

    let rateLimited = false;
    for (const branchId of fixture.branchIds) {
      try {
        await customerClient.query(
          "select public.join_waitlist($1, $2, null, $3, null, null, null) as result",
          [branchId, 2, "+628123456789"],
        );
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        expect(message).toContain("RATE_LIMIT_EXCEEDED");
        rateLimited = true;
        break;
      }
    }

    expect(rateLimited).toBe(true);

    const expectedKey = await admin.query<{ bucket_key: string }>(
      "select private.sha256_hex('customer:' || $1::text) as bucket_key",
      [customer.customerId],
    );
    const buckets = await admin.query<{ bucket_key: string }>(
      `select bucket_key
         from private.rate_limit_buckets
        where policy_key = 'waitlist_join_customer'
          and bucket_key = $1`,
      [expectedKey.rows[0]!.bucket_key],
    );

    expect(buckets.rows).toHaveLength(1);
    expect(buckets.rows[0]!.bucket_key).not.toBe(customer.customerId);
    expect(buckets.rows[0]!.bucket_key).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("session-wide guest-token revocation", () => {
  it("serializes session-wide revocation with concurrent token issuance", async () => {
    const admin = await createClient();
    const guest = await createClient();
    const manager = await createClient();
    clients.push(admin, guest, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    await authenticateAs(guest, randomUUID(), "service_role");
    const first = await guest.query<{ result: Record<string, unknown> }>(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, tokenHash()],
    );
    const sessionId = String(first.rows[0]!.result.sessionId);

    await authenticateAs(manager, managerFixture.authUserId);

    const [guestPid, managerPid] = await Promise.all([
      guest.query<{ pid: number }>("select pg_backend_pid() as pid"),
      manager.query<{ pid: number }>("select pg_backend_pid() as pid"),
    ]);

    await admin.query("begin");
    await admin.query(
      "select 1 from public.dining_sessions where id = $1 for update",
      [sessionId],
    );

    const newHash = tokenHash();
    const issueCall = guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, newHash],
    );
    const revokeCall = manager.query(
      "select public.revoke_session_guest_tokens($1, $2) as result",
      [sessionId, "race test"],
    );

    const waitForLock = async (pid: number): Promise<boolean> => {
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const result = await admin.query<{
          wait_event_type: string | null;
        }>("select wait_event_type from pg_stat_activity where pid = $1", [
          pid,
        ]);
        if (result.rows[0]?.wait_event_type === "Lock") return true;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return false;
    };

    expect(await waitForLock(guestPid.rows[0]!.pid)).toBe(true);
    expect(await waitForLock(managerPid.rows[0]!.pid)).toBe(true);

    await admin.query("commit");
    await Promise.allSettled([issueCall, revokeCall]);

    const audit = await admin.query<{ created_at: string }>(
      `select created_at::text as created_at
         from public.audit_events
        where action = 'guest_token.session_revoked'
          and target_id = $1::uuid
        order by created_at desc
        limit 1`,
      [sessionId],
    );
    expect(audit.rows[0]).toBeDefined();

    const auditTime = new Date(audit.rows[0]!.created_at);
    const tokens = await admin.query<{
      issued_at: string;
      revoked_at: string | null;
    }>(
      `select issued_at::text as issued_at, revoked_at::text as revoked_at
         from private.guest_tokens
        where dining_session_id = $1`,
      [sessionId],
    );

    for (const token of tokens.rows) {
      if (new Date(token.issued_at) < auditTime) {
        expect(token.revoked_at).not.toBeNull();
      }
    }
  });

  it("serializes token validation with session-wide revocation", async () => {
    const admin = await createClient();
    const guest = await createClient();
    const manager = await createClient();
    clients.push(admin, guest, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const hash = tokenHash();

    await authenticateAs(guest, randomUUID(), "service_role");
    const resolved = await guest.query<{ result: Record<string, unknown> }>(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, hash],
    );
    const sessionId = String(resolved.rows[0]!.result.sessionId);

    await authenticateAs(manager, managerFixture.authUserId);
    const [guestPid, managerPid] = await Promise.all([
      guest.query<{ pid: number }>("select pg_backend_pid() as pid"),
      manager.query<{ pid: number }>("select pg_backend_pid() as pid"),
    ]);

    await admin.query("begin");
    await admin.query(
      "select 1 from public.dining_sessions where id = $1 for update",
      [sessionId],
    );

    const validateCall = guest.query(
      "select public.validate_guest_token($1) as result",
      [hash],
    );
    const revokeCall = manager.query(
      "select public.revoke_session_guest_tokens($1, $2) as result",
      [sessionId, "race test"],
    );

    const waitForLock = async (pid: number): Promise<boolean> => {
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const result = await admin.query<{
          wait_event_type: string | null;
        }>(
          "select wait_event_type from pg_stat_activity where pid = $1",
          [pid],
        );
        if (result.rows[0]?.wait_event_type === "Lock") return true;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return false;
    };

    expect(await waitForLock(guestPid.rows[0]!.pid)).toBe(true);
    expect(await waitForLock(managerPid.rows[0]!.pid)).toBe(true);

    await admin.query("commit");
    await Promise.allSettled([validateCall, revokeCall]);

    const token = await admin.query<{ revoked_at: string | null }>(
      `select revoked_at::text as revoked_at
         from private.guest_tokens
        where dining_session_id = $1 and token_hash = decode($2, 'hex')`,
      [sessionId, hash],
    );

    expect(token.rows[0]!.revoked_at).not.toBeNull();
  });

  it("revokes every token for a session and audits without token material", async () => {
    const admin = await createClient();
    const guest = await createClient();
    const manager = await createClient();
    clients.push(admin, guest, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    const hashes = [tokenHash(), tokenHash()];
    await authenticateAs(guest, randomUUID(), "service_role");

    const first = await guest.query<{ result: Record<string, unknown> }>(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, hashes[0]],
    );
    const sessionId = String(first.rows[0]!.result.sessionId);

    await guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, hashes[1]],
    );

    await authenticateAs(manager, managerFixture.authUserId);
    const revoked = await manager.query<{ result: Record<string, unknown> }>(
      "select public.revoke_session_guest_tokens($1, $2) as result",
      [sessionId, "security test"],
    );

    expect(Number(revoked.rows[0]!.result.revokedCount)).toBe(2);

    await authenticateAs(guest, randomUUID(), "service_role");
    for (const hash of hashes) {
      await expectPgError(
        guest.query("select public.validate_guest_token($1) as result", [hash]),
        "GUEST_TOKEN_INVALID",
      );
    }

    const audit = await admin.query<{
      action: string;
      metadata_text: string;
    }>(
      `select action, metadata::text as metadata_text
         from public.audit_events
        where (action = 'guest_token.issued' and metadata ->> 'session_id' = $1)
           or (action = 'dining_session.created' and target_id = $1::uuid)
           or (action = 'guest_token.session_revoked' and target_id = $1::uuid)`,
      [sessionId],
    );

    expect(
      audit.rows.filter((row) => row.action === "guest_token.issued"),
    ).toHaveLength(2);
    expect(
      audit.rows.filter((row) => row.action === "dining_session.created"),
    ).toHaveLength(1);
    expect(
      audit.rows.filter((row) => row.action === "guest_token.session_revoked"),
    ).toHaveLength(1);

    for (const hash of hashes) {
      for (const row of audit.rows) {
        expect(row.metadata_text).not.toContain(hash);
      }
    }
  });
});
