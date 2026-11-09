import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import {
  RoleScopeSchema,
  STAFF_ROLES,
  StaffRoleSchema,
} from "../common/roles.ts";

export const ASSIGNABLE_STAFF_ROLES = [
  "admin",
  "manager",
  "cashier",
  "kitchen_staff",
] as const;

export type AssignableStaffRole = (typeof ASSIGNABLE_STAFF_ROLES)[number];

export const AssignableStaffRoleSchema = z.enum(ASSIGNABLE_STAFF_ROLES);

export const GrantStaffRoleRequestSchema = z
  .object({
    staffId: UuidSchema,
    role: AssignableStaffRoleSchema,
    scope: RoleScopeSchema,
    branchId: UuidSchema.nullish(),
    reason: z.string().trim().max(500).optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.role !== "admin" && value.scope !== "branch") {
      ctx.addIssue({
        code: "custom",
        path: ["scope"],
        message: "Manager, Cashier, and Kitchen Staff require branch scope",
      });
    }

    if (value.scope === "branch" && !value.branchId) {
      ctx.addIssue({
        code: "custom",
        path: ["branchId"],
        message: "Branch-scoped assignments require a branch",
      });
    }

    if (value.scope === "organization" && value.branchId != null) {
      ctx.addIssue({
        code: "custom",
        path: ["branchId"],
        message: "Organization-scoped assignments must not include a branch",
      });
    }
  });

export type GrantStaffRoleRequest = z.infer<typeof GrantStaffRoleRequestSchema>;

export const GrantStaffRoleResponseSchema = z
  .object({
    assignmentId: UuidSchema,
    staffId: UuidSchema,
    roleCode: StaffRoleSchema,
    scope: RoleScopeSchema,
    branchId: UuidSchema.nullable(),
  })
  .strict();

export type GrantStaffRoleResponse = z.infer<
  typeof GrantStaffRoleResponseSchema
>;

export const RevokeStaffRoleRequestSchema = z
  .object({
    assignmentId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type RevokeStaffRoleRequest = z.infer<
  typeof RevokeStaffRoleRequestSchema
>;

export const RevokeStaffRoleResponseSchema = z
  .object({
    assignmentId: UuidSchema,
    staffId: UuidSchema,
    branchId: UuidSchema.nullable(),
    status: z.enum(["revoked", "already_revoked"]),
  })
  .strict();

export type RevokeStaffRoleResponse = z.infer<
  typeof RevokeStaffRoleResponseSchema
>;

export const AssignStaffBranchRequestSchema = z
  .object({
    staffId: UuidSchema,
    branchId: UuidSchema,
  })
  .strict();

export type AssignStaffBranchRequest = z.infer<
  typeof AssignStaffBranchRequestSchema
>;

export const StaffBranchAssignmentResponseSchema = z
  .object({
    assignmentId: UuidSchema,
    staffId: UuidSchema,
    branchId: UuidSchema,
  })
  .strict();

export type StaffBranchAssignmentResponse = z.infer<
  typeof StaffBranchAssignmentResponseSchema
>;

export const DeactivateStaffRequestSchema = z
  .object({
    staffId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type DeactivateStaffRequest = z.infer<
  typeof DeactivateStaffRequestSchema
>;

export const StaffStatusResponseSchema = z
  .object({
    staffId: UuidSchema,
    status: z.enum(["active", "deactivated"]),
  })
  .strict();

export type StaffStatusResponse = z.infer<typeof StaffStatusResponseSchema>;

export const UpdateStaffProfileRequestSchema = z
  .object({
    staffId: UuidSchema,
    displayName: z.string().trim().min(1).max(200),
  })
  .strict();

export type UpdateStaffProfileRequest = z.infer<
  typeof UpdateStaffProfileRequestSchema
>;

export const STAFF_ROLE_CODES = STAFF_ROLES;
