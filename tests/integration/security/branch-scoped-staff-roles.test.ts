import { randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  addStaff,
  authenticateAs,
  createAuthUser,
  createOrgFixture,
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

const insertBranchRole = async (
  client: pg.Client,
  options: {
    staffId: string;
    organizationId: string;
    role: "admin" | "manager" | "cashier" | "kitchen_staff";
    branchId: string;
  },
): Promise<string> => {
  const result = await client.query<{ id: string }>(
    `insert into public.staff_role_assignments
       (staff_id, organization_id, role_code, scope_type, branch_id)
     values ($1, $2, $3, 'branch', $4)
     returning id`,
    [
      options.staffId,
      options.organizationId,
      options.role,
      options.branchId,
    ],
  );

  return result.rows[0]!.id;
};

describe("per-branch staff role resolution", () => {
  it("gives a staff member the correct role at each assigned branch", async () => {
    const admin = await createClient();
    const worker = await createClient();
    track(admin, worker);

    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchA!],
    });

    await insertBranchRole(admin, {
      staffId: staff.staffId,
      organizationId: fixture.organizationId,
      role: "cashier",
      branchId: branchB!,
    });

    await authenticateAs(worker, staff.authUserId);
    const result = await worker.query<{
      manager_a: boolean;
      manager_b: boolean;
      cashier_a: boolean;
      cashier_b: boolean;
      access_a: boolean;
      access_b: boolean;
    }>(
      `select
         authz.has_branch_role($1, array['manager']::text[]) as manager_a,
         authz.has_branch_role($2, array['manager']::text[]) as manager_b,
         authz.has_branch_role($1, array['cashier']::text[]) as cashier_a,
         authz.has_branch_role($2, array['cashier']::text[]) as cashier_b,
         authz.has_branch_access($1) as access_a,
         authz.has_branch_access($2) as access_b`,
      [branchA, branchB],
    );

    expect(result.rows[0]).toEqual({
      manager_a: true,
      manager_b: false,
      cashier_a: false,
      cashier_b: true,
      access_a: true,
      access_b: true,
    });

    const visibleBranches = await worker.query<{ id: string }>(
      "select id from public.branches order by id",
    );
    expect(visibleBranches.rows.map((row) => row.id).sort()).toEqual(
      [branchA!, branchB!].sort(),
    );
  });

  it("keeps organization-scoped Owners organization-wide", async () => {
    const admin = await createClient();
    const owner = await createClient();
    track(admin, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    await authenticateAs(owner, fixture.ownerAuthUserId);

    const result = await owner.query<{
      role_a: boolean;
      role_b: boolean;
      access_a: boolean;
      access_b: boolean;
      org_admin: boolean;
    }>(
      `select
         authz.has_branch_role($1, array['owner']::text[]) as role_a,
         authz.has_branch_role($2, array['owner']::text[]) as role_b,
         authz.has_branch_access($1) as access_a,
         authz.has_branch_access($2) as access_b,
         authz.is_org_admin() as org_admin`,
      [fixture.branchIds[0], fixture.branchIds[1]],
    );

    expect(result.rows[0]).toEqual({
      role_a: true,
      role_b: true,
      access_a: true,
      access_b: true,
      org_admin: true,
    });
  });

  it("denies access after the branch assignment is revoked", async () => {
    const admin = await createClient();
    const worker = await createClient();
    track(admin, worker);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });

    await admin.query(
      `update public.staff_branch_assignments
          set revoked_at = now()
        where staff_id = $1
          and branch_id = $2`,
      [staff.staffId, branchId],
    );

    await authenticateAs(worker, staff.authUserId);
    const result = await worker.query<{
      access: boolean;
      role: boolean;
    }>(
      `select
         authz.has_branch_access($1) as access,
         authz.has_branch_role($1, array['manager']::text[]) as role`,
      [branchId],
    );

    expect(result.rows[0]).toEqual({ access: false, role: false });
  });

  it("denies access for inactive staff", async () => {
    const admin = await createClient();
    const worker = await createClient();
    track(admin, worker);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });

    await admin.query(
      `update public.staff_profiles
          set status = 'deactivated',
              deactivated_at = now()
        where id = $1`,
      [staff.staffId],
    );

    await authenticateAs(worker, staff.authUserId);
    const result = await worker.query<{
      access: boolean;
      role: boolean;
    }>(
      `select
         authz.has_branch_access($1) as access,
         authz.has_branch_role($1, array['manager']::text[]) as role`,
      [branchId],
    );

    expect(result.rows[0]).toEqual({ access: false, role: false });
  });

  it("denies access for inactive branches", async () => {
    const admin = await createClient();
    const worker = await createClient();
    track(admin, worker);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });

    await admin.query(
      `update public.branches
          set status = 'inactive',
              deactivated_at = now()
        where id = $1`,
      [branchId],
    );

    await authenticateAs(worker, staff.authUserId);
    const result = await worker.query<{
      access: boolean;
      role: boolean;
    }>(
      `select
         authz.has_branch_access($1) as access,
         authz.has_branch_role($1, array['manager']::text[]) as role`,
      [branchId],
    );

    expect(result.rows[0]).toEqual({ access: false, role: false });
  });

  it("keeps organization-scoped Admin behavior compatible", async () => {
    const admin = await createClient();
    const worker = await createClient();
    track(admin, worker);

    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "admin",
      scope: "organization",
    });

    await authenticateAs(worker, staff.authUserId);
    const result = await worker.query<{
      org_admin: boolean;
      role_a: boolean;
      role_b: boolean;
    }>(
      `select
         authz.has_org_role(array['admin']::text[]) as org_admin,
         authz.has_branch_role($1, array['admin']::text[]) as role_a,
         authz.has_branch_role($2, array['admin']::text[]) as role_b`,
      [fixture.branchIds[0], fixture.branchIds[1]],
    );

    expect(result.rows[0]).toEqual({
      org_admin: true,
      role_a: true,
      role_b: true,
    });
  });
});

describe("branch-scoped role assignment constraints", () => {
  it("rejects duplicates and cross-organization branch identifiers", async () => {
    const admin = await createClient();
    track(admin);

    const first = await createOrgFixture(admin, { branchCount: 2 });
    const second = await createOrgFixture(admin, { branchCount: 1 });
    const [branchA, branchB] = first.branchIds;
    const staff = await addStaff(admin, {
      organizationId: first.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchA!],
    });

    await expectPgError(
      insertBranchRole(admin, {
        staffId: staff.staffId,
        organizationId: first.organizationId,
        role: "manager",
        branchId: branchA!,
      }),
      "duplicate key value violates unique constraint",
    );

    await expect(
      insertBranchRole(admin, {
        staffId: staff.staffId,
        organizationId: first.organizationId,
        role: "manager",
        branchId: branchB!,
      }),
    ).resolves.toEqual(expect.any(String));

    await expectPgError(
      admin.query(
        `insert into public.staff_role_assignments
           (staff_id, organization_id, role_code, scope_type, branch_id)
         values ($1, $2, 'cashier', 'branch', $3)`,
        [staff.staffId, first.organizationId, second.branchIds[0]],
      ),
      "violates foreign key constraint",
    );

    await expectPgError(
      admin.query(
        `insert into public.staff_role_assignments
           (staff_id, organization_id, role_code, scope_type, branch_id)
         values ($1, $2, 'cashier', 'branch', null)`,
        [staff.staffId, first.organizationId],
      ),
      "INVALID_ROLE_SCOPE",
    );

    await expectPgError(
      admin.query(
        `insert into public.staff_role_assignments
           (staff_id, organization_id, role_code, scope_type, branch_id)
         values ($1, $2, 'admin', 'organization', $3)`,
        [staff.staffId, first.organizationId, branchA],
      ),
      "INVALID_ROLE_SCOPE",
    );
  });

  it("allows a revoked assignment to be replaced", async () => {
    const admin = await createClient();
    track(admin);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "cashier",
      scope: "branch",
      branchIds: [branchId],
    });

    const oldAssignment = await admin.query<{ id: string }>(
      `select id
         from public.staff_role_assignments
        where staff_id = $1
          and role_code = 'cashier'
          and branch_id = $2
          and revoked_at is null`,
      [staff.staffId, branchId],
    );

    await admin.query(
      `update public.staff_role_assignments
          set revoked_at = now()
        where id = $1`,
      [oldAssignment.rows[0]!.id],
    );

    await expect(
      insertBranchRole(admin, {
        staffId: staff.staffId,
        organizationId: fixture.organizationId,
        role: "cashier",
        branchId,
      }),
    ).resolves.toEqual(expect.any(String));
  });

  it("still enforces one active Owner per organization", async () => {
    const admin = await createClient();
    track(admin);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const secondOwner = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "admin",
      scope: "organization",
    });

    await expectPgError(
      admin.query(
        `insert into public.staff_role_assignments
           (staff_id, organization_id, role_code, scope_type, branch_id)
         values ($1, $2, 'owner', 'organization', null)`,
        [secondOwner.staffId, fixture.organizationId],
      ),
      "duplicate key value violates unique constraint",
    );
  });
});

describe("staff role RPC branch handling", () => {
  it("grants and revokes branch roles for the requested branch", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const worker = await createClient();
    track(admin, owner, worker);

    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const other = await createOrgFixture(admin, { branchCount: 1 });
    const [branchA, branchB] = fixture.branchIds;
    const staff = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "admin",
      scope: "organization",
    });
    const secondStaffAuthUserId = await createAuthUser(admin);
    const secondStaffId = randomUUID();
    await admin.query(
      `insert into public.staff_profiles
         (id, auth_user_id, organization_id, display_name, status, activated_at)
       values ($1, $2, $3, 'Second staff', 'active', now())`,
      [secondStaffId, secondStaffAuthUserId, fixture.organizationId],
    );

    await authenticateAs(owner, fixture.ownerAuthUserId);

    const beforeGrant = await admin.query<{ exists: boolean }>(
      `select exists (
         select 1
         from public.staff_branch_assignments
         where staff_id = $1
           and branch_id = $2
           and revoked_at is null
       ) as exists`,
      [staff.staffId, branchA],
    );
    expect(beforeGrant.rows[0]!.exists).toBe(false);

    const grant = await owner.query<{
      result: {
        assignmentId: string;
        branchId: string;
        roleCode: string;
        scope: string;
        staffId: string;
      };
    }>(
      `select public.grant_staff_role($1, 'manager', 'branch', 'opens branch A', $2) as result`,
      [staff.staffId, branchA],
    );

    expect(grant.rows[0]!.result).toMatchObject({
      branchId: branchA,
      roleCode: "manager",
      scope: "branch",
      staffId: staff.staffId,
    });

    const afterGrant = await admin.query<{ exists: boolean }>(
      `select exists (
         select 1
         from public.staff_branch_assignments
         where staff_id = $1
           and branch_id = $2
           and revoked_at is null
       ) as exists`,
      [staff.staffId, branchA],
    );
    expect(afterGrant.rows[0]!.exists).toBe(true);

    await expectPgError(
      owner.query(
        `select public.grant_staff_role($1, 'manager', 'branch', null, $2)`,
        [staff.staffId, branchA],
      ),
      "RESOURCE_CONFLICT",
    );

    await expectPgError(
      owner.query(
        `select public.grant_staff_role($1, 'manager', 'branch', null, null)`,
        [staff.staffId],
      ),
      "VALIDATION_ERROR",
    );

    await expectPgError(
      owner.query(
        `select public.grant_staff_role($1, 'cashier', 'branch', null, $2)`,
        [staff.staffId, other.branchIds[0]],
      ),
      "RESOURCE_CONFLICT",
    );

    const organizationGrant = await owner.query<{
      result: { branchId: string | null; scope: string };
    }>(
      `select public.grant_staff_role($1, 'admin', 'organization', null, null) as result`,
      [secondStaffId],
    );

    expect(organizationGrant.rows[0]!.result).toMatchObject({
      branchId: null,
      scope: "organization",
    });

    await authenticateAs(worker, staff.authUserId);
    const beforeRevoke = await worker.query<{ role: boolean }>(
      "select authz.has_branch_role($1, array['manager']::text[]) as role",
      [branchA],
    );
    expect(beforeRevoke.rows[0]!.role).toBe(true);

    await owner.query("select public.revoke_staff_role($1, $2)", [
      grant.rows[0]!.result.assignmentId,
      "branch manager rotation",
    ]);

    const afterRevoke = await worker.query<{ role: boolean }>(
      "select authz.has_branch_role($1, array['manager']::text[]) as role",
      [branchA],
    );
    expect(afterRevoke.rows[0]!.role).toBe(false);
  });

  it("rejects a branch identifier that belongs to another organization", async () => {
    const admin = await createClient();
    const owner = await createClient();
    track(admin, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const other = await createOrgFixture(admin, { branchCount: 1 });
    const authUserId = await createAuthUser(admin);
    const staffId = randomUUID();

    await admin.query(
      `insert into public.staff_profiles
         (id, auth_user_id, organization_id, display_name, status, activated_at)
       values ($1, $2, $3, 'Cross tenant target', 'active', now())`,
      [staffId, authUserId, fixture.organizationId],
    );
    await admin.query(
      `insert into public.staff_branch_assignments
         (staff_id, organization_id, branch_id)
       values ($1, $2, $3)`,
      [staffId, fixture.organizationId, other.branchIds[0]],
    ).catch(() => undefined);

    await authenticateAs(owner, fixture.ownerAuthUserId);
    await expectPgError(
      owner.query(
        `select public.grant_staff_role($1, 'cashier', 'branch', null, $2)`,
        [staffId, other.branchIds[0]],
      ),
      "RESOURCE_CONFLICT",
    );
  });
});
