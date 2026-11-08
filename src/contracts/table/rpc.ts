import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";

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
