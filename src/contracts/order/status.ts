import { z } from "zod";

/**
 * Wire-level order statuses. Persisted status values are mapped by the backend
 * once Agent 1's schema is merged.
 *
 * Transition rules are not encoded here. Unapproved transitions must not be
 * implemented.
 */
export const ORDER_STATUSES = [
  "pending",
  "accepted",
  "preparing",
  "ready",
  "served",
  "cancelled",
] as const;

export type OrderStatus = (typeof ORDER_STATUSES)[number];

export const OrderStatusSchema = z.enum(ORDER_STATUSES);

/**
 * Wire-level order-item fulfilment statuses. Payment/bill state is separate.
 */
export const ORDER_ITEM_STATUSES = [
  "pending",
  "preparing",
  "ready",
  "served",
  "cancelled",
] as const;

export type OrderItemStatus = (typeof ORDER_ITEM_STATUSES)[number];

export const OrderItemStatusSchema = z.enum(ORDER_ITEM_STATUSES);
