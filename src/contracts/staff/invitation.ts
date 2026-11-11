import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { RoleScopeSchema } from "../common/roles.ts";
import { AssignableStaffRoleSchema } from "./rpc.ts";

export const STAFF_INVITATION_STATUSES = [
  "pending",
  "accepted",
  "revoked",
  "expired",
] as const;

export type StaffInvitationStatus = (typeof STAFF_INVITATION_STATUSES)[number];

export const StaffInvitationStatusSchema = z.enum(STAFF_INVITATION_STATUSES);

export const StaffInvitationSchema = z
  .object({
    invitationId: UuidSchema,
    email: z.string().email().max(320),
    displayName: z.string().min(1).max(120),
    roleCode: AssignableStaffRoleSchema,
    scope: RoleScopeSchema,
    branchId: UuidSchema.nullable(),
    status: StaffInvitationStatusSchema,
    expiresAt: z.string().min(1),
    lastSentAt: z.string().nullable(),
    sendCount: z.number().int().min(1),
    invitedByName: z.string().min(1),
    createdAt: z.string().min(1),
    acceptedAt: z.string().nullable(),
    revokedAt: z.string().nullable(),
  })
  .strict();

export type StaffInvitation = z.infer<typeof StaffInvitationSchema>;

export const ListStaffInvitationsResponseSchema = z
  .object({
    invitations: z.array(StaffInvitationSchema),
  })
  .strict();

export type ListStaffInvitationsResponse = z.infer<
  typeof ListStaffInvitationsResponseSchema
>;

const InvitationAssignmentFields = {
  role: AssignableStaffRoleSchema,
  scope: RoleScopeSchema,
  branchId: UuidSchema.nullish(),
} as const;

const validateInvitationAssignment = (
  value: {
    role: z.infer<typeof AssignableStaffRoleSchema>;
    scope: z.infer<typeof RoleScopeSchema>;
    branchId?: string | null | undefined;
  },
  ctx: z.RefinementCtx,
): void => {
  if (value.role !== "admin" && value.scope !== "branch") {
    ctx.addIssue({
      code: "custom",
      path: ["scope"],
      message:
        "Manager, Cashier, and Kitchen Staff invitations require branch scope",
    });
  }

  if (value.scope === "branch" && !value.branchId) {
    ctx.addIssue({
      code: "custom",
      path: ["branchId"],
      message: "Branch-scoped invitations require a branch",
    });
  }

  if (value.scope === "organization" && value.branchId != null) {
    ctx.addIssue({
      code: "custom",
      path: ["branchId"],
      message: "Organization-scoped invitations must not include a branch",
    });
  }
};

export const CreateStaffInvitationRequestSchema = z
  .object({
    action: z.literal("invite"),
    email: z.string().trim().email().max(320),
    displayName: z.string().trim().min(1).max(120),
    ...InvitationAssignmentFields,
    reason: z.string().trim().max(500).optional(),
  })
  .strict()
  .superRefine(validateInvitationAssignment);

export type CreateStaffInvitationRequest = z.infer<
  typeof CreateStaffInvitationRequestSchema
>;

export const ResendStaffInvitationRequestSchema = z
  .object({
    action: z.literal("resend"),
    invitationId: UuidSchema,
  })
  .strict();

export type ResendStaffInvitationRequest = z.infer<
  typeof ResendStaffInvitationRequestSchema
>;

export const StaffInviteEdgeRequestSchema = z.discriminatedUnion("action", [
  CreateStaffInvitationRequestSchema,
  ResendStaffInvitationRequestSchema,
]);

export type StaffInviteEdgeRequest = z.infer<
  typeof StaffInviteEdgeRequestSchema
>;

export const RevokeStaffInvitationRequestSchema = z
  .object({
    invitationId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type RevokeStaffInvitationRequest = z.infer<
  typeof RevokeStaffInvitationRequestSchema
>;

export const RevokeStaffInvitationResponseSchema = z
  .object({
    invitationId: UuidSchema,
    status: z.enum(["revoked", "already_revoked"]),
  })
  .strict();

export type RevokeStaffInvitationResponse = z.infer<
  typeof RevokeStaffInvitationResponseSchema
>;

export const AcceptStaffInvitationRequestSchema = z
  .object({
    token: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  })
  .strict();

export type AcceptStaffInvitationRequest = z.infer<
  typeof AcceptStaffInvitationRequestSchema
>;

export const AcceptStaffInvitationResponseSchema = z
  .object({
    staffId: UuidSchema,
    organizationId: UuidSchema,
    roleCode: AssignableStaffRoleSchema,
    scope: RoleScopeSchema,
    branchId: UuidSchema.nullable(),
  })
  .strict();

export type AcceptStaffInvitationResponse = z.infer<
  typeof AcceptStaffInvitationResponseSchema
>;

/**
 * Roles an actor may invite, derived from the actor's organization role.
 * Owner may invite Admin; Admin may not. Both may invite the branch roles.
 */
export const INVITABLE_ROLES_BY_OWNER = [
  "admin",
  "manager",
  "cashier",
  "kitchen_staff",
] as const;

export const INVITABLE_ROLES_BY_ADMIN = [
  "manager",
  "cashier",
  "kitchen_staff",
] as const;
