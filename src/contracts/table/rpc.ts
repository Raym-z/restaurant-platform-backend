import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { UtcInstantSchema } from "../common/time.ts";
import { DiningSessionDetailSchema } from "../session/rpc.ts";

export const CreateTableRequestSchema = z
  .object({
    branchId: UuidSchema,
    label: z.string().trim().min(1).max(80),
    capacity: z.number().int().min(1).max(32767),
  })
  .strict();

export type CreateTableRequest = z.infer<typeof CreateTableRequestSchema>;

export const CreateTableResponseSchema = z
  .object({
    tableId: UuidSchema,
    branchId: UuidSchema,
    qrPublicId: UuidSchema,
  })
  .strict();

export type CreateTableResponse = z.infer<typeof CreateTableResponseSchema>;

export const UpdateTableRequestSchema = z
  .object({
    tableId: UuidSchema,
    label: z.string().trim().min(1).max(80),
    capacity: z.number().int().min(1).max(32767),
  })
  .strict();

export type UpdateTableRequest = z.infer<typeof UpdateTableRequestSchema>;

export const DeactivateTableRequestSchema = z
  .object({
    tableId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type DeactivateTableRequest = z.infer<
  typeof DeactivateTableRequestSchema
>;

export const TableStatusResponseSchema = z
  .object({
    tableId: UuidSchema,
    status: z.enum(["active", "inactive"]),
  })
  .strict();

export type TableStatusResponse = z.infer<typeof TableStatusResponseSchema>;

export const RegenerateTableQrResponseSchema = z
  .object({
    tableId: UuidSchema,
    qrPublicId: UuidSchema,
  })
  .strict();

export type RegenerateTableQrResponse = z.infer<
  typeof RegenerateTableQrResponseSchema
>;

export const TABLE_AVAILABILITY_STATES = [
  "available",
  "occupied",
  "inactive",
] as const;

export type TableAvailability = (typeof TABLE_AVAILABILITY_STATES)[number];

export const TableAvailabilitySchema = z.enum(TABLE_AVAILABILITY_STATES);

export const TableSummarySchema = z
  .object({
    tableId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    label: z.string().min(1).max(80),
    capacity: z.number().int().min(1).max(32767),
    status: z.enum(["active", "inactive"]),
    deactivatedAt: UtcInstantSchema.nullable(),
    qrPublicId: UuidSchema.nullable(),
    availability: TableAvailabilitySchema,
    activeSessionId: UuidSchema.nullable(),
    activeSessionOpenedAt: UtcInstantSchema.nullable(),
  })
  .strict();

export type TableSummary = z.infer<typeof TableSummarySchema>;

export const ListBranchTablesRequestSchema = z
  .object({
    branchId: UuidSchema,
    includeInactive: z.boolean().default(false),
  })
  .strict();

export type ListBranchTablesRequest = z.infer<
  typeof ListBranchTablesRequestSchema
>;

export const ListBranchTablesResponseSchema = z
  .object({
    branchId: UuidSchema,
    tables: z.array(TableSummarySchema),
  })
  .strict();

export type ListBranchTablesResponse = z.infer<
  typeof ListBranchTablesResponseSchema
>;

export const GetTableRequestSchema = z
  .object({ tableId: UuidSchema })
  .strict();

export type GetTableRequest = z.infer<typeof GetTableRequestSchema>;

export const GetTableResponseSchema = TableSummarySchema;
export type GetTableResponse = z.infer<typeof GetTableResponseSchema>;

export const GetTableAvailabilityRequestSchema = z
  .object({ tableId: UuidSchema })
  .strict();

export type GetTableAvailabilityRequest = z.infer<
  typeof GetTableAvailabilityRequestSchema
>;

export const GetTableAvailabilityResponseSchema = z
  .object({
    tableId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    status: z.enum(["active", "inactive"]),
    availability: TableAvailabilitySchema,
    activeSessionId: UuidSchema.nullable(),
    activeSessionOpenedAt: UtcInstantSchema.nullable(),
  })
  .strict();

export type GetTableAvailabilityResponse = z.infer<
  typeof GetTableAvailabilityResponseSchema
>;

export const GetActiveDiningSessionRequestSchema = z
  .object({ tableId: UuidSchema })
  .strict();

export type GetActiveDiningSessionRequest = z.infer<
  typeof GetActiveDiningSessionRequestSchema
>;

export const GetActiveDiningSessionResponseSchema = z
  .object({
    tableId: UuidSchema,
    activeSession: DiningSessionDetailSchema.nullable(),
  })
  .strict();

export type GetActiveDiningSessionResponse = z.infer<
  typeof GetActiveDiningSessionResponseSchema
>;
