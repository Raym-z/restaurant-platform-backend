import { z } from "zod";

import { UuidSchema } from "./ids.ts";

/**
 * Exactly five organization roles are supported in the initial release.
 * Host/Queue Staff is intentionally not part of this model.
 */
export const STAFF_ROLES = [
  "owner",
  "admin",
  "manager",
  "cashier",
  "kitchen_staff",
] as const;

export type StaffRole = (typeof STAFF_ROLES)[number];

export const StaffRoleSchema = z.enum(STAFF_ROLES);

export const ROLE_SCOPES = ["organization", "branch"] as const;

export type RoleScope = (typeof ROLE_SCOPES)[number];

export const RoleScopeSchema = z.enum(ROLE_SCOPES);

/**
 * A role assignment always carries an explicit scope.
 *
 * - Owner is always organization-scoped.
 * - Admin may be organization- or branch-scoped.
 * - Manager, Cashier, and Kitchen Staff are branch-scoped.
 */
export const StaffRoleAssignmentSchema = z
  .object({
    role: StaffRoleSchema,
    scope: RoleScopeSchema,
    branchId: UuidSchema.nullable(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.role === "owner" && value.scope !== "organization") {
      ctx.addIssue({
        code: "custom",
        path: ["scope"],
        message: "Owner must be organization-scoped",
      });
    }

    if (
      value.role !== "owner" &&
      value.role !== "admin" &&
      value.scope !== "branch"
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["scope"],
        message: `${value.role} must be branch-scoped`,
      });
    }

    if (value.scope === "branch" && value.branchId === null) {
      ctx.addIssue({
        code: "custom",
        path: ["branchId"],
        message: "Branch-scoped assignments require a branch",
      });
    }

    if (value.scope === "organization" && value.branchId !== null) {
      ctx.addIssue({
        code: "custom",
        path: ["branchId"],
        message: "Organization-scoped assignments must not include a branch",
      });
    }
  });

export type StaffRoleAssignment = z.infer<typeof StaffRoleAssignmentSchema>;

/**
 * Authenticated staff context used by contracts. Permission keys are treated
 * as opaque strings here because the approved role-to-permission mapping is
 * maintained separately.
 */
export const StaffContextSchema = z
  .object({
    staffId: UuidSchema,
    organizationId: UuidSchema,
    roles: z.array(StaffRoleAssignmentSchema).min(1),
    branchIds: z.array(UuidSchema),
  })
  .strict();

export type StaffContext = z.infer<typeof StaffContextSchema>;
