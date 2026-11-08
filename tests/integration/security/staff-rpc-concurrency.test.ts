import { randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  addStaff,
  authenticateAs,
  createAuthUser,
  createOrgFixture,
  createPlatformAdmin,
  expectPgError,
} from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

const track = <T extends pg.Client[]>(...created: T): T => {
  clients.push(...created);
  return created;
};

const sleep = async (milliseconds: number): Promise<void> => {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
};

const backendPid = async (client: pg.Client): Promise<number> => {
  const result = await client.query<{ pid: number }>(
    "select pg_backend_pid() as pid",
  );
  return result.rows[0]!.pid;
};

const waitForBlockedBy = async (
  observer: pg.Client,
  pid: number,
  blockerPid: number,
): Promise<boolean> => {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    const result = await observer.query<{
      wait_event_type: string | null;
      blockers: number[];
    }>(
      `select wait_event_type, pg_blocking_pids(pid) as blockers
         from pg_stat_activity
        where pid = $1`,
      [pid],
    );
    const row = result.rows[0];
    if (row?.wait_event_type === "Lock" && row.blockers.includes(blockerPid)) {
      return true;
    }
    await sleep(10);
  }
  return false;
};

const advisoryLockCount = async (
  observer: pg.Client,
  pid: number,
): Promise<number> => {
  const result = await observer.query<{ count: number }>(
    `select count(*)::int as count
       from pg_locks
      where pid = $1
        and locktype = 'advisory'
        and granted`,
    [pid],
  );
  return result.rows[0]!.count;
};

describe("staff RPC concurrency", () => {
  it("serializes concurrent branch-assignment revocations and audits once", async () => {
    const admin = await createClient();
    const ownerA = await createClient();
    const ownerB = await createClient();
    track(admin, ownerA, ownerB);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "cashier",
      scope: "branch",
      branchIds: [branchId],
    });

    const assignment = await admin.query<{ id: string }>(
      `select id
         from public.staff_branch_assignments
        where staff_id = $1
          and branch_id = $2
          and revoked_at is null`,
      [staff.staffId, branchId],
    );
    const assignmentId = assignment.rows[0]!.id;

    await authenticateAs(ownerA, fixture.ownerAuthUserId);
    await authenticateAs(ownerB, fixture.ownerAuthUserId);
    const ownerAPid = await backendPid(ownerA);
    const ownerBPid = await backendPid(ownerB);

    await ownerA.query("begin");
    try {
      const first = await ownerA.query<{ result: { status: string } }>(
        "select public.revoke_staff_branch($1, $2) as result",
        [assignmentId, "first revocation"],
      );
      expect(first.rows[0]!.result.status).toBe("revoked");

      const secondPromise = ownerB.query<{ result: { status: string } }>(
        "select public.revoke_staff_branch($1, $2) as result",
        [assignmentId, "second revocation"],
      );

      expect(await waitForBlockedBy(admin, ownerBPid, ownerAPid)).toBe(true);
      await ownerA.query("commit");

      const second = await secondPromise;
      expect(second.rows[0]!.result.status).toBe("already_revoked");
    } catch (error) {
      await ownerA.query("rollback").catch(() => undefined);
      throw error;
    }

    const audit = await admin.query<{ count: string }>(
      `select count(*)::text as count
         from public.audit_events
        where action = 'staff.branch_revoked'
          and target_id = $1`,
      [staff.staffId],
    );
    expect(Number(audit.rows[0]!.count)).toBe(1);
  });

  it("acquires the organization advisory lock before the role-assignment row lock", async () => {
    const admin = await createClient();
    const owner = await createClient();
    track(admin, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });

    const assignment = await admin.query<{ id: string }>(
      `select id
         from public.staff_role_assignments
        where staff_id = $1
          and role_code = 'manager'
          and revoked_at is null`,
      [staff.staffId],
    );
    const assignmentId = assignment.rows[0]!.id;

    await authenticateAs(owner, fixture.ownerAuthUserId);
    const adminPid = await backendPid(admin);
    const ownerPid = await backendPid(owner);

    await admin.query("begin");
    try {
      await admin.query(
        "select 1 from public.staff_role_assignments where id = $1 for update",
        [assignmentId],
      );

      const revokePromise = owner.query<{ result: { status: string } }>(
        "select public.revoke_staff_role($1, $2) as result",
        [assignmentId, "lock-order probe"],
      );

      expect(await waitForBlockedBy(admin, ownerPid, adminPid)).toBe(true);
      expect(await advisoryLockCount(admin, ownerPid)).toBeGreaterThanOrEqual(1);

      await admin.query("commit");
      const revoked = await revokePromise;
      expect(revoked.rows[0]!.result.status).toBe("revoked");
    } catch (error) {
      await admin.query("rollback").catch(() => undefined);
      throw error;
    }
  });

  it("serializes a grant against an uncommitted revocation", async () => {
    const admin = await createClient();
    const ownerA = await createClient();
    const ownerB = await createClient();
    track(admin, ownerA, ownerB);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });

    const oldAssignment = await admin.query<{ id: string }>(
      `select id
         from public.staff_role_assignments
        where staff_id = $1
          and role_code = 'manager'
          and revoked_at is null`,
      [staff.staffId],
    );
    const oldAssignmentId = oldAssignment.rows[0]!.id;

    await authenticateAs(ownerA, fixture.ownerAuthUserId);
    await authenticateAs(ownerB, fixture.ownerAuthUserId);
    const ownerAPid = await backendPid(ownerA);
    const ownerBPid = await backendPid(ownerB);

    await ownerA.query("begin");
    try {
      const revoke = await ownerA.query<{ result: { status: string } }>(
        "select public.revoke_staff_role($1, $2) as result",
        [oldAssignmentId, "concurrent revoke"],
      );
      expect(revoke.rows[0]!.result.status).toBe("revoked");

      const grantPromise = ownerB.query<{
        result: { assignmentId: string };
      }>(
        "select public.grant_staff_role($1, 'manager', 'branch', null, $2) as result",
        [staff.staffId, branchId],
      );

      expect(await waitForBlockedBy(admin, ownerBPid, ownerAPid)).toBe(true);
      await ownerA.query("commit");

      const grant = await grantPromise;
      expect(grant.rows[0]!.result.assignmentId).toEqual(expect.any(String));
    } catch (error) {
      await ownerA.query("rollback").catch(() => undefined);
      throw error;
    }

    const roles = await admin.query<{
      id: string;
      revoked_at: string | null;
    }>(
      `select id, revoked_at
         from public.staff_role_assignments
        where staff_id = $1
          and role_code = 'manager'
          and branch_id = $2
        order by created_at`,
      [staff.staffId, branchId],
    );
    expect(roles.rows.filter((row) => row.revoked_at === null)).toHaveLength(1);
    expect(
      roles.rows.some(
        (row) => row.id === oldAssignmentId && row.revoked_at !== null,
      ),
    ).toBe(true);

    const audit = await admin.query<{ action: string; count: string }>(
      `select action, count(*)::text as count
         from public.audit_events
        where target_id = $1
          and action in ('staff.role_revoked', 'staff.role_granted')
        group by action`,
      [staff.staffId],
    );
    const counts = Object.fromEntries(
      audit.rows.map((row) => [row.action, Number(row.count)]),
    );
    expect(counts["staff.role_revoked"]).toBe(1);
    expect(counts["staff.role_granted"]).toBe(1);
  });

  it("does not hold the role row lock while waiting for organization suspension", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const platform = await createClient();
    track(admin, owner, platform);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });

    const assignment = await admin.query<{ id: string }>(
      `select id
         from public.staff_role_assignments
        where staff_id = $1
          and role_code = 'manager'
          and revoked_at is null`,
      [staff.staffId],
    );
    const assignmentId = assignment.rows[0]!.id;
    const platformAdmin = await createPlatformAdmin(admin);

    await authenticateAs(owner, fixture.ownerAuthUserId);
    await authenticateAs(platform, platformAdmin.authUserId);
    const ownerPid = await backendPid(owner);
    const platformPid = await backendPid(platform);

    await platform.query("begin");
    try {
      await platform.query(
        "select public.suspend_organization($1, $2) as result",
        [fixture.organizationId, "suspension race"],
      );

      const revokePromise = owner.query(
        "select public.revoke_staff_role($1, $2) as result",
        [assignmentId, "suspension race"],
      );

      expect(await waitForBlockedBy(admin, ownerPid, platformPid)).toBe(true);
      await platform.query("commit");

      await expectPgError(revokePromise, "ORGANIZATION_NOT_OPERATIONAL");
    } catch (error) {
      await platform.query("rollback").catch(() => undefined);
      throw error;
    }

    const role = await admin.query<{ revoked_at: string | null }>(
      "select revoked_at from public.staff_role_assignments where id = $1",
      [assignmentId],
    );
    expect(role.rows[0]!.revoked_at).toBeNull();

    const audit = await admin.query<{ count: string }>(
      `select count(*)::text as count
         from public.audit_events
        where action = 'staff.role_revoked'
          and target_id = $1`,
      [staff.staffId],
    );
    expect(Number(audit.rows[0]!.count)).toBe(0);
  });

  it("blocks branch-assignment writes while the legacy backfill locks the table", async () => {
    const admin = await createClient();
    const writer = await createClient();
    track(admin, writer);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const authUserId = await createAuthUser(admin);
    const staffId = randomUUID();

    await admin.query(
      `insert into public.staff_profiles
         (id, auth_user_id, organization_id, display_name, status, activated_at)
       values ($1, $2, $3, 'Backfill lock target', 'active', now())`,
      [staffId, authUserId, fixture.organizationId],
    );

    const adminPid = await backendPid(admin);
    const writerPid = await backendPid(writer);

    await admin.query("begin");
    try {
      await admin.query(
        "select private.backfill_legacy_branch_role_assignments()",
      );

      const writePromise = writer.query(
        `insert into public.staff_branch_assignments
           (staff_id, organization_id, branch_id)
         values ($1, $2, $3)`,
        [staffId, fixture.organizationId, branchId],
      );

      expect(await waitForBlockedBy(admin, writerPid, adminPid)).toBe(true);
      await admin.query("commit");
      await writePromise;
    } catch (error) {
      await admin.query("rollback").catch(() => undefined);
      throw error;
    }

    const assignments = await admin.query<{ count: string }>(
      `select count(*)::text as count
         from public.staff_branch_assignments
        where staff_id = $1
          and branch_id = $2
          and revoked_at is null`,
      [staffId, branchId],
    );
    expect(Number(assignments.rows[0]!.count)).toBe(1);
  });
});
