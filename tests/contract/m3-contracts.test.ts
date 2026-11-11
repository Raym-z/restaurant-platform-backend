import { describe, expect, it } from "vitest";

import {
  BranchDiningSessionListResponseSchema,
  CancelOrderRequestSchema,
  CreateOrderRequestSchema,
  DiningSessionDetailSchema,
  OrderDetailSchema,
  ORDER_STATUS_TRANSITIONS,
  TableSummarySchema,
  TransitionOrderStatusRequestSchema,
} from "../../src/index.ts";

const id = (suffix: number): string =>
  `00000000-0000-4000-8000-${String(suffix).padStart(12, "0")}`;

const orderSummary = {
  orderId: id(1),
  orderReference: "ORD-00000001",
  organizationId: id(2),
  branchId: id(3),
  diningSessionId: id(4),
  source: "staff" as const,
  status: "pending" as const,
  currency: "IDR",
  subtotalMinor: 50000,
  payableSubtotalMinor: 50000,
  notes: null,
  itemCount: 1,
  activeItemCount: 1,
  createdAt: "2026-11-08T10:00:00Z",
  updatedAt: "2026-11-08T10:00:00Z",
  acceptedAt: null,
  preparingAt: null,
  readyAt: null,
  servedAt: null,
  completedAt: null,
  cancelledAt: null,
  cancellationReason: null,
};

const orderDetail = {
  ...orderSummary,
  submittedByStaffId: id(5),
  cancelledByStaffId: null,
  items: [
    {
      orderItemId: id(6),
      orderId: id(1),
      menuItemId: id(7),
      name: "Nasi Goreng",
      baseUnitPriceMinor: 50000,
      modifierUnitDeltaMinor: 0,
      effectiveUnitPriceMinor: 50000,
      quantity: 1,
      lineTotalMinor: 50000,
      currency: "IDR",
      status: "pending",
      notes: null,
      preparingAt: null,
      readyAt: null,
      servedAt: null,
      cancelledAt: null,
      cancellationReason: null,
      modifiers: [],
    },
  ],
};

describe("M3 order contracts", () => {
  it("publishes the approved order transition map", () => {
    expect(ORDER_STATUS_TRANSITIONS.pending).toContain("accepted");
    expect(ORDER_STATUS_TRANSITIONS.served).toEqual(["completed"]);
    expect(ORDER_STATUS_TRANSITIONS.completed).toEqual([]);
    expect(ORDER_STATUS_TRANSITIONS.cancelled).toEqual([]);
  });

  it("accepts order details with authoritative snapshots", () => {
    const parsed = OrderDetailSchema.parse(orderDetail);
    expect(parsed.items[0]?.lineTotalMinor).toBe(50000);
    expect(parsed.orderReference).toBe("ORD-00000001");
  });

  it("requires a payable subtotal that can differ from the historical snapshot", () => {
    const cancelled = {
      ...orderDetail,
      status: "cancelled" as const,
      payableSubtotalMinor: 0,
    };
    const parsed = OrderDetailSchema.parse(cancelled);
    expect(parsed.subtotalMinor).toBe(50000);
    expect(parsed.payableSubtotalMinor).toBe(0);

    const withoutPayable: Record<string, unknown> = { ...orderDetail };
    delete withoutPayable.payableSubtotalMinor;
    expect(OrderDetailSchema.safeParse(withoutPayable).success).toBe(false);
  });

  it("rejects client-supplied price fields as unknown input", () => {
    expect(
      CreateOrderRequestSchema.safeParse({
        diningSessionId: id(4),
        items: [
          {
            menuItemId: id(7),
            quantity: 1,
            priceMinor: 1,
          },
        ],
      }).success,
    ).toBe(false);
  });

  it("accepts the no-price order request shape", () => {
    expect(
      CreateOrderRequestSchema.safeParse({
        diningSessionId: id(4),
        idempotencyKey: "idem-key-1234567890",
        items: [{ menuItemId: id(7), quantity: 2 }],
      }).success,
    ).toBe(true);
  });

  it("requires a cancellation reason", () => {
    expect(
      CancelOrderRequestSchema.safeParse({ orderId: id(1) }).success,
    ).toBe(false);
    expect(
      CancelOrderRequestSchema.safeParse({
        orderId: id(1),
        reason: "Customer left",
      }).success,
    ).toBe(true);
  });

  it("does not allow generic cancellation or pending targets", () => {
    expect(
      TransitionOrderStatusRequestSchema.safeParse({
        orderId: id(1),
        status: "cancelled",
      }).success,
    ).toBe(false);
    expect(
      TransitionOrderStatusRequestSchema.safeParse({
        orderId: id(1),
        status: "completed",
      }).success,
    ).toBe(true);
  });
});

describe("M3 table and session contracts", () => {
  it("accepts a table with availability and active-session metadata", () => {
    const parsed = TableSummarySchema.parse({
      tableId: id(8),
      organizationId: id(2),
      branchId: id(3),
      label: "T1",
      capacity: 4,
      status: "active",
      deactivatedAt: null,
      qrPublicId: id(9),
      availability: "occupied",
      activeSessionId: id(4),
      activeSessionOpenedAt: "2026-11-08T10:00:00Z",
    });

    expect(parsed.availability).toBe("occupied");
  });

  it("accepts a session detail with its order summaries", () => {
    const parsed = DiningSessionDetailSchema.parse({
      sessionId: id(4),
      organizationId: id(2),
      branchId: id(3),
      branchName: "Main",
      tableId: id(8),
      tableLabel: "T1",
      status: "active",
      openedAt: "2026-11-08T10:00:00Z",
      closedAt: null,
      openedByStaffId: id(5),
      closedByStaffId: null,
      currency: "IDR",
      orderCount: 1,
      activeOrderCount: 1,
      subtotalMinor: 50000,
      orders: [orderSummary],
    });

    expect(parsed.orders).toHaveLength(1);
    expect(parsed.status).toBe("active");
  });

  it("accepts paginated session lists", () => {
    expect(
      BranchDiningSessionListResponseSchema.safeParse({
        branchId: id(3),
        sessions: [],
        pageSize: 20,
        hasMore: false,
        nextOffset: null,
      }).success,
    ).toBe(true);
  });
});
