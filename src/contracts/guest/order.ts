import { z } from "zod";

import { IdempotencyKeySchema, UuidSchema } from "../common/ids.ts";
import { UtcInstantSchema } from "../common/time.ts";
import { OrderStatusSchema } from "../order/status.ts";
import { GuestTokenSchema } from "./session.ts";

/**
 * Guest order request line. Prices and totals are intentionally absent: the
 * backend resolves authoritative branch pricing and modifier effects.
 */
export const GuestOrderItemRequestSchema = z
  .object({
    menuItemId: UuidSchema,
    quantity: z.number().int().min(1).max(99),
    modifierOptionIds: z.array(UuidSchema).max(50).default([]),
    notes: z.string().max(500).optional(),
  })
  .strict();

export type GuestOrderItemRequest = z.infer<typeof GuestOrderItemRequestSchema>;

export const SubmitGuestOrderRequestSchema = z
  .object({
    guestToken: GuestTokenSchema,
    idempotencyKey: IdempotencyKeySchema,
    items: z.array(GuestOrderItemRequestSchema).min(1).max(100),
    notes: z.string().max(1000).optional(),
  })
  .strict();

export type SubmitGuestOrderRequest = z.infer<
  typeof SubmitGuestOrderRequestSchema
>;

/**
 * Minimal submission acknowledgement. Authoritative totals and item
 * snapshots are retrieved through the authorized order read path.
 */
export const SubmitGuestOrderResponseSchema = z
  .object({
    orderId: UuidSchema,
    status: OrderStatusSchema,
    createdAt: UtcInstantSchema,
  })
  .strict();

export type SubmitGuestOrderResponse = z.infer<
  typeof SubmitGuestOrderResponseSchema
>;
