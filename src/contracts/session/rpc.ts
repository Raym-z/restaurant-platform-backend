import { z } from "zod";

import { IdempotencyKeySchema, UuidSchema } from "../common/ids.ts";
import { CurrencyCodeSchema, NonNegativeMinorUnitsSchema } from "../common/money.ts";
import { UtcInstantSchema } from "../common/time.ts";
import { OrderSummarySchema } from "../order/rpc.ts";

export const DINING_SESSION_STATUSES = ["active", "closed"] as const;

export type DiningSessionStatus = (typeof DINING_SESSION_STATUSES)[number];

export const DiningSessionStatusSchema = z.enum(DINING_SESSION_STATUSES);

export const DiningSessionSummarySchema = z
  .object({
    sessionId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    branchName: z.string().min(1).max(200),
    tableId: UuidSchema,
    tableLabel: z.string().min(1).max(80),
    status: DiningSessionStatusSchema,
    openedAt: UtcInstantSchema,
    closedAt: UtcInstantSchema.nullable(),
    openedByStaffId: UuidSchema.nullable(),
    closedByStaffId: UuidSchema.nullable(),
    currency: CurrencyCodeSchema,
    orderCount: z.number().int().min(0),
    activeOrderCount: z.number().int().min(0),
    subtotalMinor: NonNegativeMinorUnitsSchema,
  })
  .strict();

export type DiningSessionSummary = z.infer<typeof DiningSessionSummarySchema>;

export const DiningSessionDetailSchema = DiningSessionSummarySchema.extend({
  orders: z.array(OrderSummarySchema),
}).strict();

export type DiningSessionDetail = z.infer<typeof DiningSessionDetailSchema>;

export const OpenDiningSessionRequestSchema = z
  .object({
    tableId: UuidSchema,
    idempotencyKey: IdempotencyKeySchema.optional(),
  })
  .strict();

export type OpenDiningSessionRequest = z.infer<
  typeof OpenDiningSessionRequestSchema
>;

export const GetDiningSessionRequestSchema = z
  .object({ sessionId: UuidSchema })
  .strict();

export type GetDiningSessionRequest = z.infer<
  typeof GetDiningSessionRequestSchema
>;

export const CloseDiningSessionRequestSchema = z
  .object({
    sessionId: UuidSchema,
    reason: z.string().trim().max(500).optional(),
  })
  .strict();

export type CloseDiningSessionRequest = z.infer<
  typeof CloseDiningSessionRequestSchema
>;

export const ListBranchDiningSessionsRequestSchema = z
  .object({
    branchId: UuidSchema,
    status: DiningSessionStatusSchema.optional(),
    from: UtcInstantSchema.optional(),
    to: UtcInstantSchema.optional(),
    limit: z.number().int().min(1).max(100).default(20),
    offset: z.number().int().min(0).default(0),
  })
  .strict();

export type ListBranchDiningSessionsRequest = z.infer<
  typeof ListBranchDiningSessionsRequestSchema
>;

export const BranchDiningSessionListResponseSchema = z
  .object({
    branchId: UuidSchema,
    sessions: z.array(DiningSessionSummarySchema),
    pageSize: z.number().int().min(1).max(100),
    hasMore: z.boolean(),
    nextOffset: z.number().int().min(0).nullable(),
  })
  .strict();

export type BranchDiningSessionListResponse = z.infer<
  typeof BranchDiningSessionListResponseSchema
>;

export const OpenDiningSessionResponseSchema = DiningSessionDetailSchema;
export type OpenDiningSessionResponse = z.infer<
  typeof OpenDiningSessionResponseSchema
>;

export const GetDiningSessionResponseSchema = DiningSessionDetailSchema;
export type GetDiningSessionResponse = z.infer<
  typeof GetDiningSessionResponseSchema
>;

export const CloseDiningSessionResponseSchema = DiningSessionDetailSchema;
export type CloseDiningSessionResponse = z.infer<
  typeof CloseDiningSessionResponseSchema
>;
