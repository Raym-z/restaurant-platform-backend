import { z } from "zod";

/**
 * Wire-level order statuses.
 *
 * `accepted` is the persisted/confirmed acceptance step. `completed` is an
 * operational completion state and is deliberately separate from payment
 * settlement and dining-session closure.
 */
export const ORDER_STATUSES = [
  "pending",
  "accepted",
  "preparing",
  "ready",
  "served",
  "completed",
  "cancelled",
] as const;

export type OrderStatus = (typeof ORDER_STATUSES)[number];

export const OrderStatusSchema = z.enum(ORDER_STATUSES);

/**
 * Approved order-level transitions implemented by the M3 backend. Cancellation
 * is a separate RPC and is allowed from pending, accepted, preparing, or ready.
 */
export const ORDER_STATUS_TRANSITIONS = {
  pending: ["accepted", "cancelled"],
  accepted: ["preparing", "cancelled"],
  preparing: ["ready", "cancelled"],
  ready: ["served", "cancelled"],
  served: ["completed"],
  completed: [],
  cancelled: [],
} as const satisfies Record<OrderStatus, readonly OrderStatus[]>;

/**
 * Wire-level order-item fulfilment statuses. Payment/bill state is separate.
 */
export const ORDER_ITEM_STATUSES = [
  "pending",
  "accepted",
  "preparing",
  "ready",
  "served",
  "cancelled",
] as const;

export type OrderItemStatus = (typeof ORDER_ITEM_STATUSES)[number];

export const OrderItemStatusSchema = z.enum(ORDER_ITEM_STATUSES);
