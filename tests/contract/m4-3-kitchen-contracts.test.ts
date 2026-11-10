import { describe, expect, it } from "vitest";

import {
  API_ERROR_CODES,
  AddKitchenStationCategoryRouteRequestSchema,
  AddKitchenStationItemRouteRequestSchema,
  CreateKitchenStationRequestSchema,
  DeactivateKitchenStationRequestSchema,
  GetKitchenTicketRequestSchema,
  KDS_REALTIME_CHANNEL_PREFIX,
  KdsRealtimeNotificationSchema,
  KdsRealtimeSubscriptionSchema,
  KitchenStationSchema,
  KitchenTicketBoardSchema,
  KitchenTicketItemTransitionRequestSchema,
  ListKitchenStationsRequestSchema,
  ListKitchenStationsResponseSchema,
  ListKitchenTicketsRequestSchema,
  ListKitchenTicketsResponseSchema,
  ReactivateKitchenStationRequestSchema,
  UpdateKitchenStationRequestSchema,
  kdsRealtimeChannelName,
} from "../../src/index.ts";

const id = (suffix: number): string =>
  `00000000-0000-4000-8000-${String(suffix).padStart(12, "0")}`;

const ticketModifier = {
  modifierGroupId: id(20),
  modifierOptionId: id(21),
  groupName: "Spice level",
  optionName: "Extra hot",
};

const boardItem = {
  ticketItemId: id(1),
  ticketId: id(2),
  orderItemId: id(3),
  menuItemId: id(4),
  name: "Nasi Goreng",
  quantity: 2,
  notes: "No onion",
  status: "preparing" as const,
  startedAt: "2026-11-10T10:01:00Z",
  readyAt: null,
  completedAt: null,
  cancelledAt: null,
  cancelledByActorType: "staff" as const,
  cancelledByStaffId: null,
  cancellationReason: null,
  createdAt: "2026-11-10T10:00:00Z",
  updatedAt: "2026-11-10T10:01:00Z",
  modifiers: [ticketModifier],
};

const board = {
  ticketId: id(2),
  organizationId: id(5),
  branchId: id(6),
  stationId: id(7),
  stationName: "Hot line",
  generation: 1,
  status: "preparing" as const,
  startedAt: "2026-11-10T10:01:00Z",
  readyAt: null,
  completedAt: null,
  cancelledAt: null,
  cancelledByActorType: "staff" as const,
  cancelledByStaffId: null,
  cancellationReason: null,
  createdAt: "2026-11-10T10:00:00Z",
  updatedAt: "2026-11-10T10:01:00Z",
  order: {
    orderId: id(3),
    orderReference: "ORD-1234",
    status: "accepted" as const,
    source: "staff" as const,
    acceptedAt: "2026-11-10T09:59:00Z",
    notes: "Birthday table",
    tableId: id(8),
    tableLabel: "T12",
  },
  items: [boardItem],
};

const station = {
  stationId: id(7),
  organizationId: id(5),
  branchId: id(6),
  name: "Hot line",
  description: "Grill and wok",
  status: "active" as const,
  deactivatedAt: null,
  createdAt: "2026-11-10T09:00:00Z",
  updatedAt: "2026-11-10T09:00:00Z",
  categoryRoutes: [
    {
      routeId: id(10),
      menuCategoryId: id(11),
      menuCategoryName: "Mains",
      createdAt: "2026-11-10T09:05:00Z",
      updatedAt: "2026-11-10T09:05:00Z",
    },
  ],
  itemRoutes: [
    {
      routeId: id(12),
      menuItemId: id(4),
      menuItemName: "Nasi Goreng",
      menuCategoryId: id(11),
      menuCategoryName: "Mains",
      createdAt: "2026-11-10T09:06:00Z",
      updatedAt: "2026-11-10T09:06:00Z",
    },
  ],
};

describe("M4.3 kitchen error codes", () => {
  it("represents every kitchen SQL error code in the shared union", () => {
    const codes = [
      "KITCHEN_TICKET_NOT_FOUND",
      "KITCHEN_TICKET_ITEM_NOT_FOUND",
      "KITCHEN_INVALID_TRANSITION",
      "KITCHEN_TICKET_CANCELLED",
      "KITCHEN_TICKET_INCONSISTENT",
      "KITCHEN_CANCELLATION_INVALID",
      "KITCHEN_STATION_NOT_FOUND",
      "KITCHEN_STATION_INACTIVE",
    ];

    for (const code of codes) {
      expect(API_ERROR_CODES).toContain(code);
    }
  });
});

describe("M4.3 kitchen transition contracts", () => {
  it("accepts a ticket-item transition request and rejects unknown fields", () => {
    expect(
      KitchenTicketItemTransitionRequestSchema.safeParse({
        ticketItemId: id(1),
      }).success,
    ).toBe(true);

    expect(
      KitchenTicketItemTransitionRequestSchema.safeParse({
        ticketItemId: id(1),
        status: "ready",
      }).success,
    ).toBe(false);

    expect(
      KitchenTicketItemTransitionRequestSchema.safeParse({
        ticketItemId: "not-a-uuid",
      }).success,
    ).toBe(false);
  });
});

describe("M4.3 KDS read contracts", () => {
  it("accepts a complete operational ticket board", () => {
    const parsed = KitchenTicketBoardSchema.parse(board);
    expect(parsed.stationName).toBe("Hot line");
    expect(parsed.order.tableLabel).toBe("T12");
    expect(parsed.items[0]?.modifiers[0]?.optionName).toBe("Extra hot");
    expect(parsed.items[0]?.notes).toBe("No onion");
  });

  it("rejects financial fields on the ticket or order context", () => {
    expect(
      KitchenTicketBoardSchema.safeParse({
        ...board,
        subtotalMinor: 25000,
      }).success,
    ).toBe(false);

    expect(
      KitchenTicketBoardSchema.safeParse({
        ...board,
        order: { ...board.order, payableSubtotalMinor: 25000 },
      }).success,
    ).toBe(false);
  });

  it("requires station, table, item, and timestamp fields", () => {
    const withoutStation: Record<string, unknown> = { ...board };
    delete withoutStation.stationName;
    expect(KitchenTicketBoardSchema.safeParse(withoutStation).success).toBe(
      false,
    );

    const withoutUpdatedAt: Record<string, unknown> = { ...boardItem };
    delete withoutUpdatedAt.updatedAt;
    expect(
      KitchenTicketBoardSchema.safeParse({
        ...board,
        items: [withoutUpdatedAt],
      }).success,
    ).toBe(false);
  });

  it("defaults list pagination and validates the page bound", () => {
    const parsed = ListKitchenTicketsRequestSchema.parse({
      branchId: id(6),
    });
    expect(parsed.limit).toBe(50);
    expect(parsed.offset).toBe(0);

    expect(
      ListKitchenTicketsRequestSchema.safeParse({
        branchId: id(6),
        limit: 101,
      }).success,
    ).toBe(false);

    expect(
      ListKitchenTicketsRequestSchema.safeParse({
        branchId: id(6),
        offset: -1,
      }).success,
    ).toBe(false);
  });

  it("requires a bounded window for history statuses", () => {
    expect(
      ListKitchenTicketsRequestSchema.safeParse({
        branchId: id(6),
        statuses: ["completed"],
      }).success,
    ).toBe(false);

    expect(
      ListKitchenTicketsRequestSchema.safeParse({
        branchId: id(6),
        statuses: ["completed"],
        from: "2026-11-01T00:00:00Z",
        to: "2026-11-02T00:00:00Z",
      }).success,
    ).toBe(true);

    expect(
      ListKitchenTicketsRequestSchema.safeParse({
        branchId: id(6),
        statuses: ["cancelled"],
        from: "2026-11-02T00:00:00Z",
        to: "2026-11-01T00:00:00Z",
      }).success,
    ).toBe(false);
  });

  it("accepts a paginated list response and rejects a malformed page", () => {
    const response = {
      branchId: id(6),
      stationId: null,
      statuses: ["pending", "preparing", "ready"],
      from: null,
      to: null,
      tickets: [board],
      pageSize: 50,
      hasMore: false,
      nextOffset: null,
    };

    expect(ListKitchenTicketsResponseSchema.safeParse(response).success).toBe(
      true,
    );

    expect(
      ListKitchenTicketsResponseSchema.safeParse({
        ...response,
        pageSize: 0,
      }).success,
    ).toBe(false);

    expect(
      ListKitchenTicketsResponseSchema.safeParse({
        ...response,
        nextOffset: undefined,
      }).success,
    ).toBe(false);
  });

  it("requires a ticket UUID for detail reads", () => {
    expect(
      GetKitchenTicketRequestSchema.safeParse({ ticketId: id(2) }).success,
    ).toBe(true);
    expect(
      GetKitchenTicketRequestSchema.safeParse({ ticketId: "nope" }).success,
    ).toBe(false);
  });
});

describe("M4.3 station management contracts", () => {
  it("accepts a station with category and item routes", () => {
    const parsed = KitchenStationSchema.parse(station);
    expect(parsed.categoryRoutes).toHaveLength(1);
    expect(parsed.itemRoutes[0]?.menuItemName).toBe("Nasi Goreng");
  });

  it("rejects an inactive station without a deactivation timestamp", () => {
    expect(
      KitchenStationSchema.safeParse({
        ...station,
        status: "inactive",
        deactivatedAt: null,
      }).success,
    ).toBe(false);
  });

  it("validates station write requests", () => {
    expect(
      CreateKitchenStationRequestSchema.safeParse({
        branchId: id(6),
        name: "  Hot line  ",
      }).success,
    ).toBe(true);

    expect(
      CreateKitchenStationRequestSchema.safeParse({
        branchId: id(6),
        name: "   ",
      }).success,
    ).toBe(false);

    expect(
      UpdateKitchenStationRequestSchema.safeParse({
        stationId: id(7),
        name: "Cold line",
      }).success,
    ).toBe(true);

    expect(
      DeactivateKitchenStationRequestSchema.safeParse({
        stationId: id(7),
        reason: "Equipment failure",
      }).success,
    ).toBe(true);

    expect(
      ReactivateKitchenStationRequestSchema.safeParse({
        stationId: id(7),
      }).success,
    ).toBe(true);
  });

  it("validates route requests", () => {
    expect(
      AddKitchenStationCategoryRouteRequestSchema.safeParse({
        stationId: id(7),
        menuCategoryId: id(11),
      }).success,
    ).toBe(true);

    expect(
      AddKitchenStationItemRouteRequestSchema.safeParse({
        stationId: id(7),
        menuItemId: id(4),
      }).success,
    ).toBe(true);

    expect(
      AddKitchenStationItemRouteRequestSchema.safeParse({
        stationId: id(7),
        menuItemId: id(4),
        menuCategoryId: id(11),
      }).success,
    ).toBe(false);
  });

  it("accepts a station list response", () => {
    expect(
      ListKitchenStationsResponseSchema.parse({
        branchId: id(6),
        stations: [station],
      }).stations,
    ).toHaveLength(1);

    expect(
      ListKitchenStationsRequestSchema.safeParse({ branchId: id(6) }).success,
    ).toBe(true);
  });
});

describe("M4.3 Realtime contracts", () => {
  it("builds a branch-scoped channel name", () => {
    expect(kdsRealtimeChannelName(id(6))).toBe(
      `${KDS_REALTIME_CHANNEL_PREFIX}${id(6)}`,
    );
  });

  it("accepts a matching subscription and rejects a mismatched channel", () => {
    expect(
      KdsRealtimeSubscriptionSchema.safeParse({
        branchId: id(6),
        channel: kdsRealtimeChannelName(id(6)),
        tables: [
          "kitchen_tickets",
          "kitchen_ticket_items",
          "kitchen_stations",
          "kitchen_station_menu_items",
          "kitchen_station_menu_categories",
        ],
      }).success,
    ).toBe(true);

    expect(
      KdsRealtimeSubscriptionSchema.safeParse({
        branchId: id(6),
        channel: kdsRealtimeChannelName(id(9)),
        tables: ["kitchen_tickets"],
      }).success,
    ).toBe(false);
  });

  it("accepts a normalized notification and rejects unsupported tables", () => {
    expect(
      KdsRealtimeNotificationSchema.safeParse({
        table: "kitchen_ticket_items",
        eventType: "UPDATE",
        branchId: id(6),
        record: { id: id(1), status: "preparing" },
        oldRecord: null,
      }).success,
    ).toBe(true);

    expect(
      KdsRealtimeNotificationSchema.safeParse({
        table: "orders",
        eventType: "UPDATE",
        branchId: id(6),
        record: { id: id(3) },
        oldRecord: null,
      }).success,
    ).toBe(false);
  });
});
