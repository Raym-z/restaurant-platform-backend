import { z } from "zod";

import {
  IdempotencyKeySchema,
  PhoneE164Schema,
  UuidSchema,
} from "../common/ids.ts";
import { IanaTimezoneSchema } from "../common/time.ts";

export const CreateBranchRequestSchema = z
  .object({
    organizationId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    timezone: IanaTimezoneSchema,
    address: z.string().trim().max(500).optional(),
    phone: PhoneE164Schema.optional(),
    idempotencyKey: IdempotencyKeySchema.optional(),
  })
  .strict();

export type CreateBranchRequest = z.infer<typeof CreateBranchRequestSchema>;

export const CreateBranchResponseSchema = z
  .object({
    branchId: UuidSchema,
    organizationId: UuidSchema,
    name: z.string().min(1).max(200),
    timezone: IanaTimezoneSchema,
  })
  .strict();

export type CreateBranchResponse = z.infer<typeof CreateBranchResponseSchema>;

export const UpdateBranchRequestSchema = z
  .object({
    branchId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    timezone: IanaTimezoneSchema,
    address: z.string().trim().max(500).optional(),
    phone: PhoneE164Schema.optional(),
  })
  .strict();

export type UpdateBranchRequest = z.infer<typeof UpdateBranchRequestSchema>;

export const DeactivateBranchRequestSchema = z
  .object({
    branchId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type DeactivateBranchRequest = z.infer<
  typeof DeactivateBranchRequestSchema
>;

export const BranchStatusResponseSchema = z
  .object({
    branchId: UuidSchema,
    status: z.enum(["active", "inactive"]),
  })
  .strict();

export type BranchStatusResponse = z.infer<typeof BranchStatusResponseSchema>;
