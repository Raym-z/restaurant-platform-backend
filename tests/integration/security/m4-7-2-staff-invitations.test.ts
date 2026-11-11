import { createHash, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  addStaff,
  authenticateAs,
  clearAuth,
  createAuthUser,
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

const connection = async (): Promise<pg.Client> => {
  const client = await createClient();
  clients.push(client);
  return client;
};

const hashToken = (raw: string): string =>
  createHash("sha256").update(raw).digest("hex");

const rawToken = (): string => randomUUID().replaceAll("-", "");

type Invitation = {
  invitationId: string;
  email: string;
  roleCode: string;
  scope: string;
  branchId: string | null;
  status: string;
};

const createInvitation = async (
  client: pg.Client,
  actor: { authUserId: string; email: string },
  options: {
    email: string;
    displayName?: string;
    role: string;
    scope: "organization" | "branch";
    branchId?: string | null;
    token?: string;
    expiresAt?: string;
  },
): Promise<Invitation> => {
  const token = options.token ?? rawToken();
  const expiresAt =
    options.expiresAt ??
    new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

  await authenticateAs(client, actor.authUserId, "authenticated", {
    email: actor.email,
  });

  const result = await client.query<{ result: Invitation }>(
    `select public.create_staff_invitation(
       $1, $2, $3, $4::public.role_scope, $5, $6, $7::timestamptz, null
     ) as result`,
    [
      options.email,
      options.displayName ?? "Invited Staff",
      options.role,
      options.scope,
      options.branchId ?? null,
      hashToken(token),
      expiresAt,
    ],
  );

  await clearAuth(client);
  return result.rows[0]!.result;
};

const acceptInvitation = async (
  client: pg.Client,
  authUserId: string,
  email: string,
  token: string,
): Promise<Record<string, unknown>> => {
  await authenticateAs(client, authUserId, "authenticated", { email });

  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.accept_staff_invitation($1) as result",
    [hashToken(token)],
  );

  await clearAuth(client);
  return result.rows[0]!.result;
};

describe("M4.7.2 staff invitations", () => {
  let client: pg.Client;
  let org: Awaited<ReturnType<typeof createOrgFixture>>;
  let admin: { authUserId: string; staffId: string };
  let manager: { authUserId: string; staffId: string };
  let cashier: { authUserId: string; staffId: string };
  let kitchen: { authUserId: string; staffId: string };
  let ownerEmail: string;

  beforeAll(async () => {
    client = await connection();
    org = await createOrgFixture(client, { branchCount: 2, branchLimit: 5 });
    admin = await addStaff(client, {
      organizationId: org.organizationId,
      role: "admin",
      scope: "organization",
    });
    manager = await addStaff(client, {
      organizationId: org.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [org.branchIds[0]!],
    });
    cashier = await addStaff(client, {
      organizationId: org.organizationId,
      role: "cashier",
      scope: "branch",
      branchIds: [org.branchIds[0]!],
    });
    kitchen = await addStaff(client, {
      organizationId: org.organizationId,
      role: "kitchen_staff",
      scope: "branch",
      branchIds: [org.branchIds[0]!],
    });
    ownerEmail = `owner-${randomUUID()}@example.test`;
    await client.query("update auth.users set email = $1 where id = $2", [
      ownerEmail,
      org.ownerAuthUserId,
    ]);
  });

  afterEach(async () => {
    await clearAuth(client).catch(() => undefined);
  });

  it("lets the Owner invite a branch-scoped Manager without leaking the token", async () => {
    const token = rawToken();
    const invitation = await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      {
        email: `manager-${randomUUID()}@example.test`,
        role: "manager",
        scope: "branch",
        branchId: org.branchIds[0]!,
        token,
      },
    );

    expect(invitation.status).toBe("pending");
    expect(invitation.roleCode).toBe("manager");
    expect(invitation.branchId).toBe(org.branchIds[0]);
    expect(JSON.stringify(invitation)).not.toContain(token);

    const rows = await client.query<{ token_hash: Buffer }>(
      "select token_hash from public.staff_invitations where id = $1",
      [invitation.invitationId],
    );
    expect(rows.rows[0]!.token_hash.toString("hex")).toBe(hashToken(token));
  });

  it("rejects duplicate pending invitations for the same email", async () => {
    const email = `duplicate-${randomUUID()}@example.test`;
    await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      { email, role: "cashier", scope: "branch", branchId: org.branchIds[0]! },
    );

    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    await expectPgError(
      client.query(
        `select public.create_staff_invitation(
           $1, 'Duplicate', 'cashier', 'branch', $2, $3,
           now() + interval '7 days', null
         )`,
        [email, org.branchIds[0]!, hashToken(rawToken())],
      ),
      "INVITATION_ALREADY_PENDING",
    );
    await clearAuth(client);
  });

  it("lets an Admin invite branch roles but not another Admin", async () => {
    const cashierEmail = `cashier-${randomUUID()}@example.test`;
    const created = await createInvitation(
      client,
      {
        authUserId: admin.authUserId,
        email: `admin-${randomUUID()}@example.test`,
      },
      {
        email: cashierEmail,
        role: "cashier",
        scope: "branch",
        branchId: org.branchIds[0]!,
      },
    );
    expect(created.roleCode).toBe("cashier");

    await authenticateAs(client, admin.authUserId, "authenticated", {
      email: `admin-${randomUUID()}@example.test`,
    });
    await expectPgError(
      client.query(
        `select public.create_staff_invitation(
           'another-admin@example.test', 'Another Admin', 'admin',
           'organization', null, $1, now() + interval '7 days', null
         )`,
        [hashToken(rawToken())],
      ),
      "PERMISSION_DENIED",
    );
    await clearAuth(client);
  });

  it("denies Manager, Cashier, and Kitchen Staff invitations", async () => {
    for (const [actor, email] of [
      [manager, `manager-${randomUUID()}@example.test`],
      [cashier, `cashier-${randomUUID()}@example.test`],
      [kitchen, `kitchen-${randomUUID()}@example.test`],
    ] as const) {
      await authenticateAs(client, actor.authUserId, "authenticated", {
        email,
      });
      await expectPgError(
        client.query(
          `select public.create_staff_invitation(
             $1, 'Denied', 'cashier', 'branch', $2, $3,
             now() + interval '7 days', null
           )`,
          [
            `denied-${randomUUID()}@example.test`,
            org.branchIds[0]!,
            hashToken(rawToken()),
          ],
        ),
        "PERMISSION_DENIED",
      );
      await clearAuth(client);
    }
  });

  it("rejects invalid roles and organization scope for branch roles", async () => {
    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });

    await expectPgError(
      client.query(
        `select public.create_staff_invitation(
           'bad-role@example.test', 'Bad Role', 'owner', 'organization', null,
           $1, now() + interval '7 days', null
         )`,
        [hashToken(rawToken())],
      ),
      "VALIDATION_ERROR",
    );

    await expectPgError(
      client.query(
        `select public.create_staff_invitation(
           'bad-scope@example.test', 'Bad Scope', 'kitchen_staff',
           'organization', null, $1, now() + interval '7 days', null
         )`,
        [hashToken(rawToken())],
      ),
      "VALIDATION_ERROR",
    );

    await clearAuth(client);
  });

  it("rejects branches from another organization", async () => {
    const other = await createOrgFixture(client, { branchCount: 1 });

    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    await expectPgError(
      client.query(
        `select public.create_staff_invitation(
           'cross-branch@example.test', 'Cross Branch', 'cashier', 'branch',
           $1, $2, now() + interval '7 days', null
         )`,
        [other.branchIds[0]!, hashToken(rawToken())],
      ),
      "BRANCH_NOT_FOUND",
    );
    await clearAuth(client);
  });

  it("rejects inviting an email that already belongs to an organization member", async () => {
    const existingEmail = `existing-${randomUUID()}@example.test`;
    const staff = await addStaff(client, {
      organizationId: org.organizationId,
      role: "cashier",
      scope: "branch",
      branchIds: [org.branchIds[0]!],
    });
    await client.query("update auth.users set email = $1 where id = $2", [
      existingEmail,
      staff.authUserId,
    ]);

    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    await expectPgError(
      client.query(
        `select public.create_staff_invitation(
           $1, 'Existing', 'cashier', 'branch', $2, $3,
           now() + interval '7 days', null
         )`,
        [existingEmail, org.branchIds[0]!, hashToken(rawToken())],
      ),
      "STAFF_ALREADY_MEMBER",
    );
    await clearAuth(client);
  });

  it("accepts only with the matching authenticated email and creates membership atomically", async () => {
    const inviteeEmail = `invitee-${randomUUID()}@example.test`;
    const inviteeAuthUserId = await createAuthUser(client);
    await client.query("update auth.users set email = $1 where id = $2", [
      inviteeEmail,
      inviteeAuthUserId,
    ]);

    const token = rawToken();
    const invitation = await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      {
        email: inviteeEmail,
        role: "kitchen_staff",
        scope: "branch",
        branchId: org.branchIds[1]!,
        token,
      },
    );

    const wrongAuthUserId = await createAuthUser(client);
    const wrongEmail = `wrong-${randomUUID()}@example.test`;
    await client.query("update auth.users set email = $1 where id = $2", [
      wrongEmail,
      wrongAuthUserId,
    ]);

    await authenticateAs(client, wrongAuthUserId, "authenticated");
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(token),
      ]),
      "INVITATION_EMAIL_MISMATCH",
    );
    await clearAuth(client);

    const accepted = await acceptInvitation(
      client,
      inviteeAuthUserId,
      inviteeEmail,
      token,
    );

    expect(accepted.organizationId).toBe(org.organizationId);
    expect(accepted.roleCode).toBe("kitchen_staff");
    expect(accepted.branchId).toBe(org.branchIds[1]);

    const profile = await client.query<{
      status: string;
      organization_id: string;
    }>(
      "select status, organization_id from public.staff_profiles where id = $1",
      [accepted.staffId],
    );
    expect(profile.rows[0]!.status).toBe("active");
    expect(profile.rows[0]!.organization_id).toBe(org.organizationId);

    const assignment = await client.query<{
      branch_id: string;
      role_code: string;
    }>(
      `select branch_id, role_code
         from public.staff_role_assignments
        where staff_id = $1 and revoked_at is null`,
      [accepted.staffId],
    );
    expect(assignment.rows[0]).toEqual({
      branch_id: org.branchIds[1],
      role_code: "kitchen_staff",
    });

    const branchAssignment = await client.query<{ count: string }>(
      `select count(*)::text as count
         from public.staff_branch_assignments
        where staff_id = $1 and branch_id = $2 and revoked_at is null`,
      [accepted.staffId, org.branchIds[1]],
    );
    expect(branchAssignment.rows[0]!.count).toBe("1");

    const invitationRow = await client.query<{ status: string }>(
      "select status from public.staff_invitations where id = $1",
      [invitation.invitationId],
    );
    expect(invitationRow.rows[0]!.status).toBe("accepted");

    await authenticateAs(client, inviteeAuthUserId, "authenticated", {
      email: inviteeEmail,
    });
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(token),
      ]),
      "INVITATION_ALREADY_ACCEPTED",
    );
    await clearAuth(client);
  });

  it("prevents a second organization membership for the same Auth account", async () => {
    const otherOrg = await createOrgFixture(client, { branchCount: 1 });
    const inviteeEmail = `one-org-${randomUUID()}@example.test`;
    const inviteeAuthUserId = await createAuthUser(client);
    await client.query("update auth.users set email = $1 where id = $2", [
      inviteeEmail,
      inviteeAuthUserId,
    ]);

    const firstToken = rawToken();
    await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      {
        email: inviteeEmail,
        role: "cashier",
        scope: "branch",
        branchId: org.branchIds[0]!,
        token: firstToken,
      },
    );
    await acceptInvitation(client, inviteeAuthUserId, inviteeEmail, firstToken);

    const otherOwnerEmail = `owner-${randomUUID()}@example.test`;
    await client.query("update auth.users set email = $1 where id = $2", [
      otherOwnerEmail,
      otherOrg.ownerAuthUserId,
    ]);

    const secondToken = rawToken();
    await createInvitation(
      client,
      { authUserId: otherOrg.ownerAuthUserId, email: otherOwnerEmail },
      {
        email: inviteeEmail,
        role: "cashier",
        scope: "branch",
        branchId: otherOrg.branchIds[0]!,
        token: secondToken,
      },
    );

    await authenticateAs(client, inviteeAuthUserId, "authenticated", {
      email: inviteeEmail,
    });
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(secondToken),
      ]),
      "STAFF_ALREADY_MEMBER",
    );
    await clearAuth(client);
  });

  it("marks expired invitations and refuses acceptance", async () => {
    const inviteeEmail = `expired-${randomUUID()}@example.test`;
    const inviteeAuthUserId = await createAuthUser(client);
    await client.query("update auth.users set email = $1 where id = $2", [
      inviteeEmail,
      inviteeAuthUserId,
    ]);

    const token = rawToken();
    const expiresAt = new Date(Date.now() - 60_000).toISOString();
    const invitationId = randomUUID();

    await client.query(
      `insert into public.staff_invitations (
         id, organization_id, branch_id, email, display_name, role_code,
         scope_type, token_hash, status, invited_by_staff_id, expires_at,
         last_sent_at, send_count, created_at
       )
       values ($1, $2, $3, $4, 'Expired', 'cashier', 'branch', $5,
               'pending', $6, $7, $8, 1, $9)`,
      [
        invitationId,
        org.organizationId,
        org.branchIds[0],
        inviteeEmail,
        Buffer.from(hashToken(token), "hex"),
        org.ownerStaffId,
        expiresAt,
        new Date(Date.now() - 2 * 60_000).toISOString(),
        new Date(Date.now() - 2 * 60_000).toISOString(),
      ],
    );

    await authenticateAs(client, inviteeAuthUserId, "authenticated", {
      email: inviteeEmail,
    });
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(token),
      ]),
      "INVITATION_EXPIRED",
    );
    await clearAuth(client);

    const row = await client.query<{ status: string }>(
      "select status from public.staff_invitations where id = $1",
      [invitationId],
    );
    expect(row.rows[0]!.status).toBe("pending");

    // Expiry is evaluated lazily. Creating a replacement for the same email
    // marks the stale pending row expired before inserting the new invitation.
    await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      {
        email: inviteeEmail,
        role: "cashier",
        scope: "branch",
        branchId: org.branchIds[0]!,
      },
    );

    const expiredRow = await client.query<{ status: string }>(
      "select status from public.staff_invitations where id = $1",
      [invitationId],
    );
    expect(expiredRow.rows[0]!.status).toBe("expired");
  });

  it("rotates the token on resend and invalidates the previous link", async () => {
    const email = `rotate-${randomUUID()}@example.test`;
    const firstToken = rawToken();
    const invitation = await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      {
        email,
        role: "cashier",
        scope: "branch",
        branchId: org.branchIds[0]!,
        token: firstToken,
      },
    );

    const secondToken = rawToken();
    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    await client.query(
      `select public.rotate_staff_invitation_token(
         $1, $2, now() + interval '7 days'
       )`,
      [invitation.invitationId, hashToken(secondToken)],
    );
    await clearAuth(client);

    const inviteeEmail = email;
    const inviteeAuthUserId = await createAuthUser(client);
    await client.query("update auth.users set email = $1 where id = $2", [
      inviteeEmail,
      inviteeAuthUserId,
    ]);

    await authenticateAs(client, inviteeAuthUserId, "authenticated", {
      email: inviteeEmail,
    });
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(firstToken),
      ]),
      "INVITATION_NOT_FOUND",
    );
    await clearAuth(client);

    const accepted = await acceptInvitation(
      client,
      inviteeAuthUserId,
      inviteeEmail,
      secondToken,
    );
    expect(accepted.roleCode).toBe("cashier");
  });

  it("revokes pending and expired invitations and audits the change", async () => {
    const email = `revoke-${randomUUID()}@example.test`;
    const invitation = await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      { email, role: "cashier", scope: "branch", branchId: org.branchIds[0]! },
    );

    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    const revoked = await client.query<{ result: { status: string } }>(
      "select public.revoke_staff_invitation($1, 'Test revocation') as result",
      [invitation.invitationId],
    );
    expect(revoked.rows[0]!.result.status).toBe("revoked");
    await clearAuth(client);

    const audit = await client.query<{ count: string }>(
      `select count(*)::text as count
         from public.audit_events
        where action = 'staff.invitation_revoked'
          and target_id = $1`,
      [invitation.invitationId],
    );
    expect(audit.rows[0]!.count).toBe("1");
  });

  it("enforces organization isolation for list, revoke, and resend", async () => {
    const other = await createOrgFixture(client, { branchCount: 1 });
    const otherOwnerEmail = `owner-${randomUUID()}@example.test`;
    await client.query("update auth.users set email = $1 where id = $2", [
      otherOwnerEmail,
      other.ownerAuthUserId,
    ]);

    const invitation = await createInvitation(
      client,
      { authUserId: other.ownerAuthUserId, email: otherOwnerEmail },
      {
        email: `isolated-${randomUUID()}@example.test`,
        role: "cashier",
        scope: "branch",
        branchId: other.branchIds[0]!,
      },
    );

    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });

    await expectPgError(
      client.query("select public.revoke_staff_invitation($1, 'Nope')", [
        invitation.invitationId,
      ]),
      "INVITATION_NOT_FOUND",
    );

    await expectPgError(
      client.query(
        `select public.rotate_staff_invitation_token(
           $1, $2, now() + interval '7 days'
         )`,
        [invitation.invitationId, hashToken(rawToken())],
      ),
      "INVITATION_NOT_FOUND",
    );

    const listed = await client.query<{
      result: { invitations: Array<{ invitationId: string }> };
    }>("select public.list_staff_invitations(100) as result");
    expect(
      listed.rows[0]!.result.invitations.some(
        (entry) => entry.invitationId === invitation.invitationId,
      ),
    ).toBe(false);

    await clearAuth(client);

    await authenticateAs(client, manager.authUserId, "authenticated", {
      email: `manager-${randomUUID()}@example.test`,
    });
    await expectPgError(
      client.query("select public.list_staff_invitations(100)"),
      "PERMISSION_DENIED",
    );
    await clearAuth(client);
  });

  it("refuses acceptance when the branch was deactivated after invitation", async () => {
    const inviteeEmail = `branch-closed-${randomUUID()}@example.test`;
    const inviteeAuthUserId = await createAuthUser(client);
    await client.query("update auth.users set email = $1 where id = $2", [
      inviteeEmail,
      inviteeAuthUserId,
    ]);

    const branch = await client.query<{ id: string }>(
      `insert into public.branches (organization_id, name, timezone)
       values ($1, 'Closing Branch', 'Asia/Jakarta') returning id`,
      [org.organizationId],
    );
    const branchId = branch.rows[0]!.id;

    const token = rawToken();
    await createInvitation(
      client,
      { authUserId: org.ownerAuthUserId, email: ownerEmail },
      {
        email: inviteeEmail,
        role: "cashier",
        scope: "branch",
        branchId,
        token,
      },
    );

    await client.query(
      "update public.branches set status = 'inactive', deactivated_at = now() where id = $1",
      [branchId],
    );

    await authenticateAs(client, inviteeAuthUserId, "authenticated", {
      email: inviteeEmail,
    });
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(token),
      ]),
      "BRANCH_NOT_ACTIVE",
    );
    await clearAuth(client);

    const profiles = await client.query<{ count: string }>(
      "select count(*)::text as count from public.staff_profiles where auth_user_id = $1",
      [inviteeAuthUserId],
    );
    expect(profiles.rows[0]!.count).toBe("0");
  });

  it("seeds a deterministic active Free plan and lets a new Owner register", async () => {
    const free = await client.query<{
      code: string;
      branch_limit: number;
    }>(
      "select code, branch_limit from public.plans where is_free and is_active",
    );
    expect(free.rows).toHaveLength(1);
    expect(free.rows[0]!.code).toBe("free");
    expect(free.rows[0]!.branch_limit).toBe(1);

    const authUserId = await createAuthUser(client);
    await authenticateAs(client, authUserId, "authenticated", {
      email: `new-owner-${randomUUID()}@example.test`,
    });

    const registered = await client.query<{
      result: {
        organizationId: string;
        branchId: string;
        staffId: string;
        planCode: string;
      };
    }>(
      `select public.register_organization(
         $1, 'Acceptance Org', 'Asia/Jakarta', 'Acceptance Owner'
       ) as result`,
      [`M4 Acceptance ${randomUUID()}`],
    );

    expect(registered.rows[0]!.result.planCode).toBe("free");

    await expectPgError(
      client.query(
        "select public.create_branch($1, 'Second Branch', 'Asia/Jakarta')",
        [registered.rows[0]!.result.organizationId],
      ),
      "BRANCH_LIMIT_REACHED",
    );

    await clearAuth(client);
  });

  it("does not expose token hashes through the invitation list", async () => {
    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    const listed = await client.query<{ result: unknown }>(
      "select public.list_staff_invitations(100) as result",
    );
    const serialized = JSON.stringify(listed.rows[0]!.result);

    expect(serialized).not.toContain("token");
    expect(serialized).not.toContain("hash");
    await clearAuth(client);
  });

  it("revalidates inviter authority and leaves no partial membership", async () => {
    const inviteeEmail = `reauth-${randomUUID()}@example.test`;
    const inviteeAuthUserId = await createAuthUser(client);
    await client.query("update auth.users set email = $1 where id = $2", [
      inviteeEmail,
      inviteeAuthUserId,
    ]);

    const token = rawToken();
    await createInvitation(
      client,
      { authUserId: admin.authUserId, email: "admin@example.test" },
      {
        email: inviteeEmail,
        role: "cashier",
        scope: "branch",
        branchId: org.branchIds[0]!,
        token,
      },
    );

    await authenticateAs(client, org.ownerAuthUserId, "authenticated", {
      email: ownerEmail,
    });
    await client.query("select public.deactivate_staff($1, 'Authority lost')", [
      admin.staffId,
    ]);
    await clearAuth(client);

    await authenticateAs(client, inviteeAuthUserId, "authenticated", {
      email: inviteeEmail,
    });
    await expectPgError(
      client.query("select public.accept_staff_invitation($1)", [
        hashToken(token),
      ]),
      "INVITATION_REVOKED",
    );
    await clearAuth(client);

    const profiles = await client.query<{ count: string }>(
      "select count(*)::text as count from public.staff_profiles where auth_user_id = $1",
      [inviteeAuthUserId],
    );
    expect(profiles.rows[0]!.count).toBe("0");

    const invitationRow = await client.query<{ status: string }>(
      "select status from public.staff_invitations where email = $1",
      [inviteeEmail],
    );
    expect(invitationRow.rows[0]!.status).toBe("pending");
  });

  it("keeps table fixtures independent of invitations", async () => {
    const table = await createTable(client, {
      organizationId: org.organizationId,
      branchId: org.branchIds[0]!,
      label: `INV-${randomUUID().slice(0, 8)}`,
    });
    expect(table.tableId).toBeTruthy();
  });
});
