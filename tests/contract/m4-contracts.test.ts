import { describe, expect, it } from "vitest";

import {
  KitchenTicketSchema,
  ListKitchenRoutingIssuesRequestSchema,
  ListKitchenRoutingIssuesResponseSchema,
} from "../../src/index.ts";

const id = (suffix: number): string =>
  `00000000-0000-4000-8000-${String(suffix).padStart(12, "0")}`;

const ticketItem = {
  ticketItemId: id(1),
  ticketId: id(2),
  orderId: id(3),
  orderItemId: id(4),
  organizationId: id(5),
  branchId: id(6),
  menuItemId: id(7),
  name: "Nasi Goreng",
  quantity: 1,
  notes: null,
  status: "pending" as const,
  startedAt: null,
  readyAt: null,
  completedAt: null,
  cancelledAt: null,
  cancelledByActorType: "staff" as const,
  cancelledByStaffId: null,
  cancellationReason: null,
  createdAt: "2026-11-09T10:00:00Z",
  updatedAt: "2026-11-09T10:00:00Z",
};

const ticket = {
  ticketId: id(2),
  organizationId: id(5),
  branchId: id(6),
  orderId: id(3),
  stationId: id(8),
  generation: 1,
  status: "pending" as const,
  startedAt: null,
  readyAt: null,
  completedAt: null,
  cancelledAt: null,
  cancelledByActorType: "staff" as const,
  cancelledByStaffId: null,
  cancellationReason: null,
  createdAt: "2026-11-09T10:00:00Z",
  updatedAt: "2026-11-09T10:00:00Z",
  items: [ticketItem],
};

const routingIssue = {
  issueType: "inactive_item_route" as const,
  branchId: id(6),
  menuItemId: id(7),
  menuItemName: "Nasi Goreng",
  menuCategoryId: id(9),
  menuCategoryName: "Mains",
  stationId: id(8),
  stationName: "Hot line",
  stationStatus: "inactive" as const,
  categoryRouteActive: true,
};

describe("M4 kitchen ticket contracts", () => {
  it("accepts a ticket with generation and cancellation actor fields", () => {
    const parsed = KitchenTicketSchema.parse(ticket);
    expect(parsed.generation).toBe(1);
    expect(parsed.cancelledByActorType).toBe("staff");
    expect(parsed.items[0]?.status).toBe("pending");
  });

  it("requires generation and cancellation actor fields", () => {
    const withoutGeneration: Record<string, unknown> = { ...ticket };
    delete withoutGeneration.generation;
    expect(KitchenTicketSchema.safeParse(withoutGeneration).success).toBe(false);

    const withoutActorType: Record<string, unknown> = { ...ticket };
    delete withoutActorType.cancelledByActorType;
    expect(KitchenTicketSchema.safeParse(withoutActorType).success).toBe(false);
  });

  it("accepts a system cancellation actor without a staff identifier", () => {
    const cancelled = KitchenTicketSchema.parse({
      ...ticket,
      status: "cancelled",
      cancelledAt: "2026-11-09T10:05:00Z",
      cancelledByActorType: "system",
      cancelledByStaffId: null,
      cancellationReason: "System cleanup",
    });
    expect(cancelled.cancelledByActorType).toBe("system");
    expect(cancelled.cancelledByStaffId).toBeNull();
  });
});

describe("M4 routing issue contracts", () => {
  it("accepts the inactive item-route issue shape", () => {
    const response = ListKitchenRoutingIssuesResponseSchema.parse({
      branchId: id(6),
      issues: [routingIssue],
    });
    expect(response.issues[0]?.issueType).toBe("inactive_item_route");
    if (response.issues[0]?.issueType === "inactive_item_route") {
      expect(response.issues[0].categoryRouteActive).toBe(true);
    }
  });

  it("accepts the inactive category-route issue shape", () => {
    expect(
      ListKitchenRoutingIssuesResponseSchema.safeParse({
        branchId: id(6),
        issues: [
          {
            issueType: "inactive_category_route",
            branchId: id(6),
            menuCategoryId: id(9),
            menuCategoryName: "Mains",
            stationId: id(8),
            stationName: "Hot line",
            stationStatus: "inactive",
          },
        ],
      }).success,
    ).toBe(true);
  });

  it("rejects unknown issue types and missing category-route state", () => {
    expect(
      ListKitchenRoutingIssuesResponseSchema.safeParse({
        branchId: id(6),
        issues: [{ ...routingIssue, issueType: "unknown" }],
      }).success,
    ).toBe(false);

    const withoutCategoryState: Record<string, unknown> = { ...routingIssue };
    delete withoutCategoryState.categoryRouteActive;
    expect(
      ListKitchenRoutingIssuesResponseSchema.safeParse({
        branchId: id(6),
        issues: [withoutCategoryState],
      }).success,
    ).toBe(false);
  });

  it("requires a branch UUID request", () => {
    expect(
      ListKitchenRoutingIssuesRequestSchema.safeParse({ branchId: id(6) })
        .success,
    ).toBe(true);
    expect(
      ListKitchenRoutingIssuesRequestSchema.safeParse({ branchId: "nope" })
        .success,
    ).toBe(false);
  });
});
