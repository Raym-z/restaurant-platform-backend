import { z } from "zod";

import {
  IdempotencyKeySchema,
  PhoneE164Schema,
  UuidSchema,
} from "../common/ids.ts";
import { CurrencyCodeSchema } from "../common/money.ts";
import { IanaTimezoneSchema } from "../common/time.ts";

export const RegisterOrganizationRequestSchema = z
  .object({
    name: z.string().trim().min(1).max(200),
    branchName: z.string().trim().min(1).max(200),
    branchTimezone: IanaTimezoneSchema,
    ownerDisplayName: z.string().trim().min(1).max(200),
    branchAddress: z.string().trim().max(500).optional(),
    branchPhone: PhoneE164Schema.optional(),
    currencyCode: CurrencyCodeSchema.default("IDR"),
    idempotencyKey: IdempotencyKeySchema.optional(),
  })
  .strict();

export type RegisterOrganizationRequest = z.infer<
  typeof RegisterOrganizationRequestSchema
>;

export const RegisterOrganizationResponseSchema = z
  .object({
    organizationId: UuidSchema,
    branchId: UuidSchema,
    staffId: UuidSchema,
    planCode: z.string().min(1).max(80),
  })
  .strict();

export type RegisterOrganizationResponse = z.infer<
  typeof RegisterOrganizationResponseSchema
>;

export const UpdateOrganizationRequestSchema = z
  .object({
    organizationId: UuidSchema,
    name: z.string().trim().min(1).max(200),
  })
  .strict();

export type UpdateOrganizationRequest = z.infer<
  typeof UpdateOrganizationRequestSchema
>;

export const OrganizationSummaryResponseSchema = z
  .object({
    organizationId: UuidSchema,
    name: z.string().min(1).max(200),
  })
  .strict();

export type OrganizationSummaryResponse = z.infer<
  typeof OrganizationSummaryResponseSchema
>;
