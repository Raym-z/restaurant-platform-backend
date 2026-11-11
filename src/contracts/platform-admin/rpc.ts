import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { UtcInstantSchema } from "../common/time.ts";

export const ListOrganizationsRequestSchema = z
  .object({
    page: z.number().int().min(1).default(1),
    pageSize: z.number().int().min(1).max(100).default(20),
  })
  .strict();

export type ListOrganizationsRequest = z.infer<
  typeof ListOrganizationsRequestSchema
>;

export const OrganizationMetadataSummarySchema = z
  .object({
    organizationId: UuidSchema,
    name: z.string().min(1).max(200),
    status: z.enum(["active", "suspended", "pending_deletion"]),
    createdAt: UtcInstantSchema,
    branchCount: z.number().int().min(0),
  })
  .strict();

export type OrganizationMetadataSummary = z.infer<
  typeof OrganizationMetadataSummarySchema
>;

export const ListOrganizationsResponseSchema = z
  .object({
    organizations: z.array(OrganizationMetadataSummarySchema),
    page: z.number().int().min(1),
    pageSize: z.number().int().min(1).max(100),
    hasMore: z.boolean(),
  })
  .strict();

export type ListOrganizationsResponse = z.infer<
  typeof ListOrganizationsResponseSchema
>;

export const OrganizationMetadataResponseSchema = z
  .object({
    organizationId: UuidSchema,
    name: z.string().min(1).max(200),
    status: z.enum(["active", "suspended", "pending_deletion"]),
    defaultCurrencyCode: z.string().regex(/^[A-Z]{3}$/),
    createdAt: UtcInstantSchema,
    deletionRequestedAt: UtcInstantSchema.nullable(),
    deletionScheduledFor: UtcInstantSchema.nullable(),
    branches: z.array(
      z
        .object({
          branchId: UuidSchema,
          name: z.string().min(1).max(200),
          timezone: z.string().min(1).max(64),
          status: z.enum(["active", "inactive"]),
        })
        .strict(),
    ),
  })
  .strict();

export type OrganizationMetadataResponse = z.infer<
  typeof OrganizationMetadataResponseSchema
>;

export const OrganizationActionRequestSchema = z
  .object({
    organizationId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type OrganizationActionRequest = z.infer<
  typeof OrganizationActionRequestSchema
>;

export const OrganizationStatusResponseSchema = z
  .object({
    organizationId: UuidSchema,
    status: z.enum(["active", "suspended", "pending_deletion"]),
  })
  .strict();

export type OrganizationStatusResponse = z.infer<
  typeof OrganizationStatusResponseSchema
>;
