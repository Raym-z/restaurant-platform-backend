// Shared M2/M3 integration fixtures.
//
// addStaff() writes staff_role_assignments.branch_id for every branch-scoped
// role. Carry this revision into the M3 integration; do not merge an older
// helper variant that omitted branch_id.
import { randomUUID } from "node:crypto";

import type pg from "pg";

export type AuthRole = "authenticated" | "service_role";

export type OrgFixture = {
  organizationId: string;
  branchIds: string[];
  ownerAuthUserId: string;
  ownerStaffId: string;
  planCode: string;
};

export const createAuthUser = async (
  client: pg.Client,
  authUserId = randomUUID(),
): Promise<string> => {
  await client.query(
    "insert into auth.users (id) values ($1) on conflict (id) do nothing",
    [authUserId],
  );
  return authUserId;
};

export const authenticateAs = async (
  client: pg.Client,
  authUserId: string,
  role: AuthRole = "authenticated",
  claims: Record<string, unknown> = {},
): Promise<void> => {
  const now = Math.floor(Date.now() / 1000);
  const payload = JSON.stringify({
    sub: authUserId,
    role,
    aud: "authenticated",
    iss: "http://127.0.0.1:54321/auth/v1",
    iat: now,
    exp: now + 3600,
    ...claims,
  });

  await client.query(
    `select set_config('request.jwt.claims', $1, false),
            set_config('request.jwt.claim.sub', $2, false),
            set_config('request.jwt.claim.role', $3, false)`,
    [payload, authUserId, role],
  );
  await client.query(`set role ${role}`);
};

export const clearAuth = async (client: pg.Client): Promise<void> => {
  await client.query("reset role");
  await client.query(
    "select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claim.role', '', false)",
  );
};

export const createOrgFixture = async (
  client: pg.Client,
  options: {
    branchCount?: number;
    branchLimit?: number | null;
    includeSubscription?: boolean;
  } = {},
): Promise<OrgFixture> => {
  const branchCount = options.branchCount ?? 1;
  const branchLimit =
    options.branchLimit === undefined ? 10 : options.branchLimit;

  const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
  const planCode = `test_plan_${suffix}`;
  const organizationId = randomUUID();
  const ownerAuthUserId = await createAuthUser(client);
  const ownerStaffId = randomUUID();

  await client.query(
    `insert into public.plans (code, name, is_free, branch_limit)
     values ($1, $2, false, $3)`,
    [planCode, `Test plan ${suffix}`, branchLimit],
  );

  await client.query(
    `insert into public.organizations (id, name, default_currency_code)
     values ($1, $2, 'IDR')`,
    [organizationId, `Test org ${suffix}`],
  );

  const branchIds: string[] = [];
  for (let index = 0; index < branchCount; index += 1) {
    const branchId = randomUUID();
    branchIds.push(branchId);
    await client.query(
      `insert into public.branches (id, organization_id, name, timezone)
       values ($1, $2, $3, 'Asia/Jakarta')`,
      [branchId, organizationId, `Branch ${index + 1}`],
    );
  }

  await client.query(
    `insert into public.staff_profiles
       (id, auth_user_id, organization_id, display_name, status, activated_at)
     values ($1, $2, $3, 'Owner', 'active', now())`,
    [ownerStaffId, ownerAuthUserId, organizationId],
  );

  await client.query(
    `insert into public.staff_role_assignments
       (staff_id, organization_id, role_code, scope_type)
     values ($1, $2, 'owner', 'organization')`,
    [ownerStaffId, organizationId],
  );

  if (options.includeSubscription !== false) {
    await client.query(
      `insert into public.subscriptions (organization_id, plan_code, state)
       values ($1, $2, 'active')`,
      [organizationId, planCode],
    );
  }

  return {
    organizationId,
    branchIds,
    ownerAuthUserId,
    ownerStaffId,
    planCode,
  };
};

export const addStaff = async (
  client: pg.Client,
  options: {
    organizationId: string;
    role: "admin" | "manager" | "cashier" | "kitchen_staff";
    scope: "organization" | "branch";
    branchIds?: string[];
  },
): Promise<{ authUserId: string; staffId: string }> => {
  const authUserId = await createAuthUser(client);
  const staffId = randomUUID();

  await client.query(
    `insert into public.staff_profiles
       (id, auth_user_id, organization_id, display_name, status, activated_at)
     values ($1, $2, $3, $4, 'active', now())`,
    [staffId, authUserId, options.organizationId, options.role],
  );

  const branchIds = options.branchIds ?? [];

  if (options.scope === "branch" && branchIds.length === 0) {
    throw new Error("Branch-scoped staff fixtures require at least one branch");
  }

  for (const branchId of branchIds) {
    await client.query(
      `insert into public.staff_branch_assignments
         (staff_id, organization_id, branch_id)
       values ($1, $2, $3)`,
      [staffId, options.organizationId, branchId],
    );
  }

  if (options.scope === "organization") {
    await client.query(
      `insert into public.staff_role_assignments
         (staff_id, organization_id, role_code, scope_type, branch_id)
       values ($1, $2, $3, $4, null)`,
      [staffId, options.organizationId, options.role, options.scope],
    );
  } else {
    for (const branchId of branchIds) {
      await client.query(
        `insert into public.staff_role_assignments
           (staff_id, organization_id, role_code, scope_type, branch_id)
         values ($1, $2, $3, $4, $5)`,
        [
          staffId,
          options.organizationId,
          options.role,
          options.scope,
          branchId,
        ],
      );
    }
  }

  return { authUserId, staffId };
};

export const createPlatformAdmin = async (
  client: pg.Client,
): Promise<{ authUserId: string; platformAdminId: string }> => {
  const authUserId = await createAuthUser(client);
  const platformAdminId = randomUUID();

  await client.query(
    `insert into public.platform_admins (id, auth_user_id)
     values ($1, $2)`,
    [platformAdminId, authUserId],
  );

  return { authUserId, platformAdminId };
};

export const createCustomer = async (
  client: pg.Client,
): Promise<{ authUserId: string; customerId: string }> => {
  const authUserId = await createAuthUser(client);
  const customerId = randomUUID();

  await client.query(
    `insert into public.customer_profiles (id, auth_user_id, full_name, phone)
     values ($1, $2, 'Test Customer', '+628123456789')`,
    [customerId, authUserId],
  );

  return { authUserId, customerId };
};

export const createTable = async (
  client: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    label?: string;
  },
): Promise<{ tableId: string; qrPublicId: string }> => {
  const tableId = randomUUID();
  const qrPublicId = randomUUID();

  await client.query(
    `insert into public.restaurant_tables
       (id, organization_id, branch_id, label, capacity)
     values ($1, $2, $3, $4, 4)`,
    [tableId, options.organizationId, options.branchId, options.label ?? "T1"],
  );

  await client.query(
    `insert into public.table_qr_identifiers
       (id, organization_id, branch_id, table_id, public_id)
     values ($1, $2, $3, $4, $5)`,
    [
      randomUUID(),
      options.organizationId,
      options.branchId,
      tableId,
      qrPublicId,
    ],
  );

  return { tableId, qrPublicId };
};

export const setOrganizationStatus = async (
  client: pg.Client,
  organizationId: string,
  status: "active" | "suspended" | "pending_deletion",
): Promise<void> => {
  if (status === "pending_deletion") {
    await client.query(
      `update public.organizations
          set status = 'pending_deletion',
              deletion_requested_at = now(),
              deletion_scheduled_for = now() + interval '30 days'
        where id = $1`,
      [organizationId],
    );
    return;
  }

  await client.query(
    `update public.organizations
        set status = $2,
            deletion_requested_at = null,
            deletion_scheduled_for = null
      where id = $1`,
    [organizationId, status],
  );
};

export const expectPgError = async (
  promise: Promise<unknown>,
  code: string,
): Promise<void> => {
  try {
    await promise;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes(code)) {
      throw new Error(`Expected ${code}, received: ${message}`);
    }
    return;
  }

  throw new Error(`Expected ${code}, but the operation succeeded`);
};

export type CapturedPgError = {
  message: string;
  detail: string | undefined;
  code: string | undefined;
};

export type KitchenRoutingIssue = Record<string, unknown>;

export type KitchenRoutingIssuesResponse = {
  branchId: string;
  issues: KitchenRoutingIssue[];
};

export const listRoutingIssues = async (
  client: pg.Client,
  branchId: string,
): Promise<KitchenRoutingIssuesResponse> => {
  const result = await client.query<{ result: KitchenRoutingIssuesResponse }>(
    "select public.list_kitchen_routing_issues($1) as result",
    [branchId],
  );
  return result.rows[0]!.result;
};

export const capturePgError = async (
  promise: Promise<unknown>,
): Promise<CapturedPgError> => {
  try {
    await promise;
  } catch (error) {
    const record = error as { message?: string; detail?: string; code?: string };
    return {
      message: record.message ?? String(error),
      detail: record.detail,
      code: record.code,
    };
  }

  throw new Error("Expected an error, but the operation succeeded");
};
