import { z } from "zod";

import { IdempotencyKeySchema, UuidSchema } from "../common/ids.ts";
import { CurrencyCodeSchema, NonNegativeMinorUnitsSchema } from "../common/money.ts";
import { UtcInstantSchema } from "../common/time.ts";
import {
  ORDER_STATUSES,
  OrderItemStatusSchema,
  OrderStatusSchema,
} from "./status.ts";

const NullableInstantSchema = UtcInstantSchema.nullable();
const NullableTextSchema = z.string().max(1000).nullable();

export const OrderSourceSchema = z.enum(["guest", "staff"]);

export const OrderItemModifierSchema = z
  .object({
    modifierGroupId: UuidSchema,
    modifierOptionId: UuidSchema,
    groupName: z.string().min(1).max(200),
    optionName: z.string().min(1).max(200),
    priceDeltaMinor: z.number().int(),
  })
  .strict();

export type OrderItemModifier = z.infer<typeof OrderItemModifierSchema>;

export const OrderItemSchema = z
  .object({
    orderItemId: UuidSchema,
    orderId: UuidSchema,
    menuItemId: UuidSchema,
    name: z.string().min(1).max(200),
    baseUnitPriceMinor: NonNegativeMinorUnitsSchema,
    modifierUnitDeltaMinor: z.number().int(),
    effectiveUnitPriceMinor: NonNegativeMinorUnitsSchema,
    quantity: z.number().int().min(1).max(99),
    lineTotalMinor: NonNegativeMinorUnitsSchema,
    currency: CurrencyCodeSchema,
    status: OrderItemStatusSchema,
    notes: z.string().max(500).nullable(),
    preparingAt: NullableInstantSchema,
    readyAt: NullableInstantSchema,
    servedAt: NullableInstantSchema,
    cancelledAt: NullableInstantSchema,
    cancellationReason: z.string().max(500).nullable(),
    modifiers: z.array(OrderItemModifierSchema),
  })
  .strict();

export type OrderItem = z.infer<typeof OrderItemSchema>;

export const OrderSummarySchema = z
  .object({
    orderId: UuidSchema,
    orderReference: z.string().min(1).max(64),
    organizationId: UuidSchema,
    branchId: UuidSchema,
    diningSessionId: UuidSchema,
    source: OrderSourceSchema,
    status: OrderStatusSchema,
    currency: CurrencyCodeSchema,
    subtotalMinor: NonNegativeMinorUnitsSchema,
    notes: NullableTextSchema,
    itemCount: z.number().int().min(0),
    activeItemCount: z.number().int().min(0),
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
    acceptedAt: NullableInstantSchema,
    preparingAt: NullableInstantSchema,
    readyAt: NullableInstantSchema,
    servedAt: NullableInstantSchema,
    completedAt: NullableInstantSchema,
    cancelledAt: NullableInstantSchema,
    cancellationReason: z.string().max(500).nullable(),
  })
  .strict();

export type OrderSummary = z.infer<typeof OrderSummarySchema>;

export const OrderDetailSchema = OrderSummarySchema.extend({
  submittedByStaffId: UuidSchema.nullable(),
  cancelledByStaffId: UuidSchema.nullable(),
  items: z.array(OrderItemSchema),
}).strict();

export type OrderDetail = z.infer<typeof OrderDetailSchema>;

export const CreateOrderItemRequestSchema = z
  .object({
    menuItemId: UuidSchema,
    quantity: z.number().int().min(1).max(99),
    modifierOptionIds: z.array(UuidSchema).max(50).default([]),
    notes: z.string().trim().max(500).optional(),
  })
  .strict();

export type CreateOrderItemRequest = z.infer<
  typeof CreateOrderItemRequestSchema
>;

export const CreateOrderRequestSchema = z
  .object({
    diningSessionId: UuidSchema,
    items: z.array(CreateOrderItemRequestSchema).min(1).max(100),
    notes: z.string().trim().max(1000).optional(),
    idempotencyKey: IdempotencyKeySchema.optional(),
  })
  .strict();

export type CreateOrderRequest = z.infer<typeof CreateOrderRequestSchema>;

export const GetOrderRequestSchema = z
  .object({ orderId: UuidSchema })
  .strict();

export type GetOrderRequest = z.infer<typeof GetOrderRequestSchema>;

export const ListOrdersBySessionRequestSchema = z
  .object({
    diningSessionId: UuidSchema,
    status: OrderStatusSchema.optional(),
    limit: z.number().int().min(1).max(100).default(20),
    offset: z.number().int().min(0).default(0),
  })
  .strict();

export type ListOrdersBySessionRequest = z.infer<
  typeof ListOrdersBySessionRequestSchema
>;

export const ListBranchOrdersRequestSchema = z
  .object({
    branchId: UuidSchema,
    status: OrderStatusSchema.optional(),
    from: UtcInstantSchema.optional(),
    to: UtcInstantSchema.optional(),
    limit: z.number().int().min(1).max(100).default(20),
    offset: z.number().int().min(0).default(0),
  })
  .strict();

export type ListBranchOrdersRequest = z.infer<
  typeof ListBranchOrdersRequestSchema
>;

export const SessionOrderListResponseSchema = z
  .object({
    diningSessionId: UuidSchema,
    orders: z.array(OrderSummarySchema),
    pageSize: z.number().int().min(1).max(100),
    hasMore: z.boolean(),
    nextOffset: z.number().int().min(0).nullable(),
  })
  .strict();

export type SessionOrderListResponse = z.infer<
  typeof SessionOrderListResponseSchema
>;

export const BranchOrderListResponseSchema = z
  .object({
    branchId: UuidSchema,
    orders: z.array(OrderSummarySchema),
    pageSize: z.number().int().min(1).max(100),
    hasMore: z.boolean(),
    nextOffset: z.number().int().min(0).nullable(),
  })
  .strict();

export type BranchOrderListResponse = z.infer<
  typeof BranchOrderListResponseSchema
>;

export const AddOrderItemRequestSchema = z
  .object({
    orderId: UuidSchema,
    menuItemId: UuidSchema,
    quantity: z.number().int().min(1).max(99),
    modifierOptionIds: z.array(UuidSchema).max(50).default([]),
    notes: z.string().trim().max(500).optional(),
  })
  .strict();

export type AddOrderItemRequest = z.infer<typeof AddOrderItemRequestSchema>;

export const UpdateOrderItemQuantityRequestSchema = z
  .object({
    orderItemId: UuidSchema,
    quantity: z.number().int().min(1).max(99),
  })
  .strict();

export type UpdateOrderItemQuantityRequest = z.infer<
  typeof UpdateOrderItemQuantityRequestSchema
>;

export const RemoveOrderItemRequestSchema = z
  .object({
    orderItemId: UuidSchema,
    reason: z.string().trim().max(500).optional(),
  })
  .strict();

export type RemoveOrderItemRequest = z.infer<
  typeof RemoveOrderItemRequestSchema
>;

/**
 * The generic transition RPC rejects pending/cancelled targets. Cancellation
 * uses the dedicated cancellation contract so a reason is mandatory.
 */
export const TRANSITION_TARGET_STATUSES = [
  "accepted",
  "preparing",
  "ready",
  "served",
  "completed",
] as const;

export const TransitionOrderStatusRequestSchema = z
  .object({
    orderId: UuidSchema,
    status: z.enum(TRANSITION_TARGET_STATUSES),
    reason: z.string().trim().max(500).optional(),
  })
  .strict();

export type TransitionOrderStatusRequest = z.infer<
  typeof TransitionOrderStatusRequestSchema
>;

export const CancelOrderRequestSchema = z
  .object({
    orderId: UuidSchema,
    reason: z.string().trim().min(1).max(500),
  })
  .strict();

export type CancelOrderRequest = z.infer<typeof CancelOrderRequestSchema>;

export const OrderDetailResponseSchema = OrderDetailSchema;
export type OrderDetailResponse = z.infer<typeof OrderDetailResponseSchema>;

/**
 * Runtime guard that the transition map and the published status union cannot
 * drift apart silently.
 */
export const isOrderStatus = (value: unknown): value is (typeof ORDER_STATUSES)[number] =>
  typeof value === "string" &&
  (ORDER_STATUSES as readonly string[]).includes(value);
