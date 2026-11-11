import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { CurrencyCodeSchema } from "../common/money.ts";
import { IanaTimezoneSchema, UtcInstantSchema } from "../common/time.ts";
import { OrderItemStatusSchema, OrderStatusSchema } from "../order/status.ts";

/**
 * Raw guest token. This is never persisted; only its SHA-256 hash is stored.
 * The token is returned once to the requesting device over TLS.
 */
export const GuestTokenSchema = z
  .string()
  .min(32)
  .max(512)
  .regex(
    /^[A-Za-z0-9_-]+$/,
    "Must be an opaque base64url-compatible guest token",
  );

export type GuestToken = z.infer<typeof GuestTokenSchema>;

export const GuestDeviceLabelSchema = z.string().min(1).max(120);

export type GuestDeviceLabel = z.infer<typeof GuestDeviceLabelSchema>;

export const GuestSessionStatusSchema = z.enum(["active", "closed"]);

export type GuestSessionStatus = z.infer<typeof GuestSessionStatusSchema>;

export const GuestSessionContextSchema = z
  .object({
    sessionId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    tableId: UuidSchema,
    tableLabel: z.string().min(1).max(80),
    branchName: z.string().min(1).max(160),
    timezone: IanaTimezoneSchema,
    currency: CurrencyCodeSchema,
    status: GuestSessionStatusSchema,
    openedAt: UtcInstantSchema,
  })
  .strict();

export type GuestSessionContext = z.infer<typeof GuestSessionContextSchema>;

export const ResolveTableRequestSchema = z
  .object({
    qrIdentifier: UuidSchema,
    deviceLabel: GuestDeviceLabelSchema.optional(),
  })
  .strict();

export type ResolveTableRequest = z.infer<typeof ResolveTableRequestSchema>;

/**
 * The raw token is returned exactly once. Clients must not assume it can be
 * retrieved again from persisted state.
 */
export const ResolveTableResponseSchema = z
  .object({
    session: GuestSessionContextSchema,
    guestToken: GuestTokenSchema,
    tokenExpiresAt: UtcInstantSchema,
  })
  .strict();

export type ResolveTableResponse = z.infer<typeof ResolveTableResponseSchema>;

export const GuestReconnectRequestSchema = z
  .object({
    guestToken: GuestTokenSchema,
  })
  .strict();

export type GuestReconnectRequest = z.infer<typeof GuestReconnectRequestSchema>;

export const GuestSessionDataRequestSchema = z
  .object({
    guestToken: GuestTokenSchema,
  })
  .strict();

export type GuestSessionDataRequest = z.infer<
  typeof GuestSessionDataRequestSchema
>;

export const GuestSessionResponseSchema = z
  .object({
    session: GuestSessionContextSchema,
  })
  .strict();

export type GuestSessionResponse = z.infer<typeof GuestSessionResponseSchema>;

export const GuestOrderItemSummarySchema = z
  .object({
    orderItemId: UuidSchema,
    name: z.string().min(1).max(200),
    quantity: z.number().int().min(1),
    status: OrderItemStatusSchema,
    lineTotalMinor: z.number().int(),
  })
  .strict();

export type GuestOrderItemSummary = z.infer<typeof GuestOrderItemSummarySchema>;

export const GuestOrderSummarySchema = z
  .object({
    orderId: UuidSchema,
    status: OrderStatusSchema,
    subtotalMinor: z.number().int(),
    createdAt: UtcInstantSchema,
    items: z.array(GuestOrderItemSummarySchema),
  })
  .strict();

export type GuestOrderSummary = z.infer<typeof GuestOrderSummarySchema>;

export const GuestSessionDataResponseSchema = z
  .object({
    session: GuestSessionContextSchema,
    orders: z.array(GuestOrderSummarySchema),
  })
  .strict();

export type GuestSessionDataResponse = z.infer<
  typeof GuestSessionDataResponseSchema
>;
