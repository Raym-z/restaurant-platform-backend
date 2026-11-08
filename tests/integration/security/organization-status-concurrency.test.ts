import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  authenticateAs,
  createOrgFixture,
  createPlatformAdmin,
  createTable,
} from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

const tokenHash = (): string => randomBytes(32).toString("hex");

const waitForOrgLock = async (
  observer: pg.Client,
  pid: number,
): Promise<boolean> => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await observer.query<{ wait_event_type: string | null }>(
      "select wait_event_type from pg_stat_activity where pid = $1",
      [pid],
    );
    if (result.rows[0]?.wait_event_type === "Lock") return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
};

describe("organization status concurrency", () => {
  it("allows concurrent operational mutations to share the organization lock", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    await authenticateAs(owner, fixture.ownerAuthUserId);

    const ownerPid = await owner.query<{ pid: number }>(
      "select pg_backend_pid() as pid",
    );

    await admin.query("begin");
    await admin.query(
      `select pg_advisory_xact_lock_shared(hashtextextended('organization:' || $1::text, 0))`,
      [fixture.organizationId],
    );

    try {
      const mutation = owner.query(
        "select public.create_menu_category('Concurrent category', null, 0) as result",
      );
      await new Promise((resolve) => setTimeout(resolve, 150));

      const activity = await admin.query<{ wait_event_type: string | null }>(
        "select wait_event_type from pg_stat_activity where pid = $1",
        [ownerPid.rows[0]!.pid],
      );

      expect(activity.rows[0]?.wait_event_type).not.toBe("Lock");
      await mutation;
    } finally {
      await admin.query("commit");
    }
  });

  it("serializes suspension against branch creation", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const platform = await createClient();
    clients.push(admin, owner, platform);

    const fixture = await createOrgFixture(admin, { branchCount: 0 });
    const platformAdmin = await createPlatformAdmin(admin);

    await authenticateAs(owner, fixture.ownerAuthUserId);
    await authenticateAs(platform, platformAdmin.authUserId);

    await admin.query("begin");
    await admin.query(
      `select pg_advisory_xact_lock(hashtextextended('organization:' || $1::text, 0))`,
      [fixture.organizationId],
    );

    const [createPid, suspendPid] = await Promise.all([
      owner.query<{ pid: number }>("select pg_backend_pid() as pid"),
      platform.query<{ pid: number }>("select pg_backend_pid() as pid"),
    ]);

    const createCall = owner.query(
      "select public.create_branch($1, $2, $3, null, null, null) as result",
      [fixture.organizationId, "Race branch", "Asia/Jakarta"],
    );
    const suspendCall = platform.query(
      "select public.suspend_organization($1, $2) as result",
      [fixture.organizationId, "race test"],
    );

    const createWaits = await waitForOrgLock(admin, createPid.rows[0]!.pid);
    const suspendWaits = await waitForOrgLock(admin, suspendPid.rows[0]!.pid);

    await admin.query("commit");

    const results = await Promise.allSettled([createCall, suspendCall]);

    expect(createWaits).toBe(true);
    expect(suspendWaits).toBe(true);
    expect(results[1]!.status).toBe("fulfilled");

    const organization = await admin.query<{ status: string }>(
      "select status::text as status from public.organizations where id = $1",
      [fixture.organizationId],
    );
    expect(organization.rows[0]!.status).toBe("suspended");
  });

  it("serializes suspension against existing guest-token validation", async () => {
    const admin = await createClient();
    const guest = await createClient();
    const platform = await createClient();
    clients.push(admin, guest, platform);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const platformAdmin = await createPlatformAdmin(admin);
    const hash = tokenHash();

    await authenticateAs(guest, randomUUID(), "service_role");
    await guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, hash],
    );

    await authenticateAs(platform, platformAdmin.authUserId);

    await admin.query("begin");
    await admin.query(
      `select pg_advisory_xact_lock(hashtextextended('organization:' || $1::text, 0))`,
      [fixture.organizationId],
    );

    const [guestPid, platformPid] = await Promise.all([
      guest.query<{ pid: number }>("select pg_backend_pid() as pid"),
      platform.query<{ pid: number }>("select pg_backend_pid() as pid"),
    ]);

    const validateCall = guest.query(
      "select public.validate_guest_token($1) as result",
      [hash],
    );
    const suspendCall = platform.query(
      "select public.suspend_organization($1, $2) as result",
      [fixture.organizationId, "race test"],
    );

    const validateWaits = await waitForOrgLock(admin, guestPid.rows[0]!.pid);
    const suspendWaits = await waitForOrgLock(admin, platformPid.rows[0]!.pid);

    await admin.query("commit");
    await Promise.allSettled([validateCall, suspendCall]);

    expect(validateWaits).toBe(true);
    expect(suspendWaits).toBe(true);

    const organization = await admin.query<{ status: string }>(
      "select status::text as status from public.organizations where id = $1",
      [fixture.organizationId],
    );
    expect(organization.rows[0]!.status).toBe("suspended");

    try {
      await guest.query("select public.validate_guest_token($1) as result", [
        hash,
      ]);
      throw new Error("expected suspended token validation to fail");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      expect(message).toContain("GUEST_TOKEN_INVALID");
    }
  });
});
