import { describe, expect, it } from "vitest";

import {
  AcceptStaffInvitationRequestSchema,
  CreateStaffInvitationRequestSchema,
  INVITABLE_ROLES_BY_ADMIN,
  INVITABLE_ROLES_BY_OWNER,
  ListStaffInvitationsResponseSchema,
  ResendStaffInvitationRequestSchema,
  StaffInvitationSchema,
  StaffInviteEdgeRequestSchema,
} from "../../src/index.ts";
import {
  buildAcceptanceRedirect,
  isExistingAuthUserError,
  normalizeInvitationEmail,
} from "../../supabase/functions/_shared/staffInvite.ts";

const invitation = {
  invitationId: "00000000-0000-4000-8000-000000000001",
  email: "manager@example.test",
  displayName: "Acceptance Manager",
  roleCode: "manager",
  scope: "branch",
  branchId: "00000000-0000-4000-8000-000000000002",
  status: "pending",
  expiresAt: "2026-11-17T10:00:00.000Z",
  lastSentAt: "2026-11-10T10:00:00.000Z",
  sendCount: 1,
  invitedByName: "Acceptance Owner",
  createdAt: "2026-11-10T10:00:00.000Z",
  acceptedAt: null,
  revokedAt: null,
} as const;

describe("staff invitation contracts", () => {
  it("accepts a branch-scoped Manager invitation", () => {
    const parsed = CreateStaffInvitationRequestSchema.parse({
      action: "invite",
      email: "Manager@Example.Test",
      displayName: "Acceptance Manager",
      role: "manager",
      scope: "branch",
      branchId: invitation.branchId,
    });

    expect(parsed.email).toBe("Manager@Example.Test");
  });

  it("rejects organization-scoped Manager invitations", () => {
    const result = CreateStaffInvitationRequestSchema.safeParse({
      action: "invite",
      email: "manager@example.test",
      displayName: "Acceptance Manager",
      role: "manager",
      scope: "organization",
      branchId: null,
    });

    expect(result.success).toBe(false);
  });

  it("rejects branch-scoped invitations without a branch", () => {
    const result = CreateStaffInvitationRequestSchema.safeParse({
      action: "invite",
      email: "cashier@example.test",
      displayName: "Acceptance Cashier",
      role: "cashier",
      scope: "branch",
    });

    expect(result.success).toBe(false);
  });

  it("allows organization-scoped Admin invitations", () => {
    const parsed = CreateStaffInvitationRequestSchema.parse({
      action: "invite",
      email: "admin@example.test",
      displayName: "Acceptance Admin",
      role: "admin",
      scope: "organization",
    });

    expect(parsed.scope).toBe("organization");
  });

  it("discriminates the Edge request actions", () => {
    expect(
      StaffInviteEdgeRequestSchema.safeParse({
        action: "resend",
        invitationId: invitation.invitationId,
      }).success,
    ).toBe(true);

    expect(
      StaffInviteEdgeRequestSchema.safeParse({
        action: "invite",
        email: "not-an-email",
        displayName: "X",
        role: "cashier",
        scope: "branch",
        branchId: invitation.branchId,
      }).success,
    ).toBe(false);
  });

  it("parses the invitation response and list envelope", () => {
    expect(StaffInvitationSchema.parse(invitation)).toEqual(invitation);
    expect(
      ListStaffInvitationsResponseSchema.parse({ invitations: [invitation] })
        .invitations,
    ).toHaveLength(1);
  });

  it("requires a 43-character acceptance token", () => {
    expect(
      AcceptStaffInvitationRequestSchema.safeParse({
        token: "a".repeat(43),
      }).success,
    ).toBe(true);
    expect(
      AcceptStaffInvitationRequestSchema.safeParse({ token: "short" }).success,
    ).toBe(false);
  });

  it("exposes the correct invitable role sets", () => {
    expect(INVITABLE_ROLES_BY_OWNER).toContain("admin");
    expect(INVITABLE_ROLES_BY_ADMIN).not.toContain("admin");
    expect(INVITABLE_ROLES_BY_ADMIN).toEqual([
      "manager",
      "cashier",
      "kitchen_staff",
    ]);
  });

  it("rejects an unknown resend field", () => {
    expect(
      ResendStaffInvitationRequestSchema.safeParse({
        action: "resend",
        invitationId: invitation.invitationId,
        email: "leak@example.test",
      }).success,
    ).toBe(false);
  });
});

describe("staff invitation Edge helpers", () => {
  it("normalizes email case and whitespace", () => {
    expect(normalizeInvitationEmail("  Manager@Example.Test ")).toBe(
      "manager@example.test",
    );
  });

  it("classifies existing Auth account errors without treating other failures as existing", () => {
    expect(
      isExistingAuthUserError({
        message: "A user with this email address has already been registered",
      }),
    ).toBe(true);
    expect(isExistingAuthUserError({ message: "User already exists" })).toBe(
      true,
    );
    expect(
      isExistingAuthUserError({ message: "Email rate limit exceeded" }),
    ).toBe(false);
  });

  it("builds an acceptance redirect that preserves existing query parameters", () => {
    const redirect = buildAcceptanceRedirect(
      "https://pos.example.test/accept-invitation?source=email",
      "abc_DEF-123",
    );
    const parsed = new URL(redirect);

    expect(parsed.pathname).toBe("/accept-invitation");
    expect(parsed.searchParams.get("source")).toBe("email");
    expect(parsed.searchParams.get("invitation")).toBe("abc_DEF-123");
  });
});
