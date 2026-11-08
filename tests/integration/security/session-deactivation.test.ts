import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  addStaff,
  authenticateAs,
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

describe("guest session creation versus table deactivation", () => {
  it("serializes resolve and table deactivation without leaving an active session on an inactive table", async () => {
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
    await authenticateAs(manager, managerFixture.authUserId);

    const resolveCall = guest.query<{ result: Record<string, unknown> }>(
      "select public.resolve_or_create_dining_session($1, $2, $3, now() + interval '1 hour') as result",
      [table.qrPublicId, tokenHash(), "device-race"],
    );
    const deactivateCall = manager.query(
      "select public.deactivate_table($1, $2) as result",
      [table.tableId, "race test"],
    );

    const results = await Promise.allSettled([resolveCall, deactivateCall]);
    const resolved = results[0]!;
    const deactivated = results[1]!;

    const state = await admin.query<{
      table_status: string;
      active_sessions: string;
    }>(
      `select rt.status::text as table_status,
              (select count(*)::text
                 from public.dining_sessions ds
                where ds.table_id = rt.id
                  and ds.status = 'active') as active_sessions
         from public.restaurant_tables rt
        where rt.id = $1`,
      [table.tableId],
    );

    expect(state.rows[0]).toBeDefined();
    const row = state.rows[0]!;

    if (row.table_status === "inactive") {
      expect(Number(row.active_sessions)).toBe(0);
    } else {
      expect(Number(row.active_sessions)).toBe(1);
    }

    if (resolved.status === "fulfilled") {
      expect(deactivated.status).toBe("rejected");
    } else {
      expect(deactivated.status).toBe("fulfilled");
    }
  });

  it("serializes resolve and branch deactivation", async () => {
    const admin = await createClient();
    const guest = await createClient();
    const owner = await createClient();
    clients.push(admin, guest, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    await authenticateAs(guest, randomUUID(), "service_role");
    await authenticateAs(owner, fixture.ownerAuthUserId);

    const resolveCall = guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, tokenHash()],
    );
    const deactivateCall = owner.query(
      "select public.deactivate_branch($1, $2) as result",
      [branchId, "race test"],
    );

    const results = await Promise.allSettled([resolveCall, deactivateCall]);
    const resolved = results[0]!;
    const deactivated = results[1]!;

    const state = await admin.query<{
      branch_status: string;
      active_sessions: string;
    }>(
      `select b.status::text as branch_status,
              (select count(*)::text
                 from public.dining_sessions ds
                where ds.branch_id = b.id
                  and ds.status = 'active') as active_sessions
         from public.branches b
        where b.id = $1`,
      [branchId],
    );

    const row = state.rows[0]!;
    if (row.branch_status === "inactive") {
      expect(Number(row.active_sessions)).toBe(0);
    } else {
      expect(Number(row.active_sessions)).toBe(1);
    }

    if (resolved.status === "fulfilled") {
      expect(deactivated.status).toBe("rejected");
    } else {
      expect(deactivated.status).toBe("fulfilled");
    }
  });

  it("rechecks QR state after acquiring the table lock", async () => {
    const admin = await createClient();
    const guest = await createClient();
    clients.push(admin, guest);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    await authenticateAs(guest, randomUUID(), "service_role");
    const guestPid = await guest.query<{ pid: number }>(
      "select pg_backend_pid() as pid",
    );

    await admin.query("begin");
    await admin.query(
      "select 1 from public.restaurant_tables where id = $1 for update",
      [table.tableId],
    );

    const resolvePromise = guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, tokenHash()],
    );

    let waiting = false;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const activity = await admin.query<{ wait_event_type: string | null }>(
        "select wait_event_type from pg_stat_activity where pid = $1",
        [guestPid.rows[0]!.pid],
      );
      if (activity.rows[0]?.wait_event_type === "Lock") {
        waiting = true;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }

    if (!waiting) {
      await admin.query("rollback");
      throw new Error(
        "guest session resolution did not block on the table lock",
      );
    }

    await admin.query(
      "update public.table_qr_identifiers set revoked_at = now() where table_id = $1 and revoked_at is null",
      [table.tableId],
    );
    await admin.query("commit");

    await expect(resolvePromise).rejects.toThrow(/TABLE_QR_INVALID/);
  });

  it("rejects resolution with a revoked QR", async () => {
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

    await authenticateAs(manager, managerFixture.authUserId);
    await manager.query("select public.regenerate_table_qr($1) as result", [
      table.tableId,
    ]);

    await authenticateAs(guest, randomUUID(), "service_role");
    await expectPgError(
      guest.query(
        "select public.resolve_or_create_dining_session($1, $2, $3, now() + interval '1 hour') as result",
        [table.qrPublicId, tokenHash(), "device-old-qr"],
      ),
      "TABLE_QR_INVALID",
    );
  });
});
