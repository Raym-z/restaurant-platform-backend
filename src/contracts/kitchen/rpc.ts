import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { UtcInstantSchema } from "../common/time.ts";
import { OrderSourceSchema } from "../order/rpc.ts";
import { OrderStatusSchema } from "../order/status.ts";

const NullableInstantSchema = UtcInstantSchema.nullable();
const NullableReasonSchema = z.string().max(500).nullable();

export const KitchenTicketStatusSchema = z.enum([
  "pending",
  "preparing",
  "ready",
  "completed",
  "cancelled",
]);

export type KitchenTicketStatus = z.infer<typeof KitchenTicketStatusSchema>;

export const KitchenCancellationActorTypeSchema = z.enum(["staff", "system"]);

export type KitchenCancellationActorType = z.infer<
  typeof KitchenCancellationActorTypeSchema
>;

export const KitchenTicketItemSchema = z
  .object({
    ticketItemId: UuidSchema,
    ticketId: UuidSchema,
    orderId: UuidSchema,
    orderItemId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    menuItemId: UuidSchema,
    name: z.string().min(1).max(200),
    quantity: z.number().int().min(1).max(99),
    notes: z.string().max(500).nullable(),
    status: KitchenTicketStatusSchema,
    startedAt: NullableInstantSchema,
    readyAt: NullableInstantSchema,
    completedAt: NullableInstantSchema,
    cancelledAt: NullableInstantSchema,
    cancelledByActorType: KitchenCancellationActorTypeSchema,
    cancelledByStaffId: UuidSchema.nullable(),
    cancellationReason: z.string().max(500).nullable(),
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
  })
  .strict();

export type KitchenTicketItem = z.infer<typeof KitchenTicketItemSchema>;

export const KitchenTicketSchema = z
  .object({
    ticketId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    orderId: UuidSchema,
    stationId: UuidSchema,
    generation: z.number().int().min(1),
    status: KitchenTicketStatusSchema,
    startedAt: NullableInstantSchema,
    readyAt: NullableInstantSchema,
    completedAt: NullableInstantSchema,
    cancelledAt: NullableInstantSchema,
    cancelledByActorType: KitchenCancellationActorTypeSchema,
    cancelledByStaffId: UuidSchema.nullable(),
    cancellationReason: z.string().max(500).nullable(),
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
    items: z.array(KitchenTicketItemSchema),
  })
  .strict();

export type KitchenTicket = z.infer<typeof KitchenTicketSchema>;

export const KitchenTicketItemTransitionResponseSchema = KitchenTicketSchema;
export type KitchenTicketItemTransitionResponse = z.infer<
  typeof KitchenTicketItemTransitionResponseSchema
>;

const KitchenRoutingIssueBaseSchema = z.object({
  branchId: UuidSchema,
  stationId: UuidSchema,
  stationName: z.string().min(1).max(200),
  stationStatus: z.literal("inactive"),
});

export const InactiveItemRouteIssueSchema = KitchenRoutingIssueBaseSchema.extend({
  issueType: z.literal("inactive_item_route"),
  menuItemId: UuidSchema,
  menuItemName: z.string().min(1).max(200),
  menuCategoryId: UuidSchema,
  menuCategoryName: z.string().min(1).max(200),
  categoryRouteActive: z.boolean(),
}).strict();

export type InactiveItemRouteIssue = z.infer<
  typeof InactiveItemRouteIssueSchema
>;

export const InactiveCategoryRouteIssueSchema =
  KitchenRoutingIssueBaseSchema.extend({
    issueType: z.literal("inactive_category_route"),
    menuCategoryId: UuidSchema,
    menuCategoryName: z.string().min(1).max(200),
  }).strict();

export type InactiveCategoryRouteIssue = z.infer<
  typeof InactiveCategoryRouteIssueSchema
>;

export const KitchenRoutingIssueSchema = z.discriminatedUnion("issueType", [
  InactiveItemRouteIssueSchema,
  InactiveCategoryRouteIssueSchema,
]);

export type KitchenRoutingIssue = z.infer<typeof KitchenRoutingIssueSchema>;

export const ListKitchenRoutingIssuesRequestSchema = z
  .object({ branchId: UuidSchema })
  .strict();

export type ListKitchenRoutingIssuesRequest = z.infer<
  typeof ListKitchenRoutingIssuesRequestSchema
>;

export const ListKitchenRoutingIssuesResponseSchema = z
  .object({
    branchId: UuidSchema,
    issues: z.array(KitchenRoutingIssueSchema),
  })
  .strict();

export type ListKitchenRoutingIssuesResponse = z.infer<
  typeof ListKitchenRoutingIssuesResponseSchema
>;

// ---------------------------------------------------------------------------
// M4.3 — Transition request contracts
// ---------------------------------------------------------------------------

export const KitchenTicketItemTransitionRequestSchema = z
  .object({ ticketItemId: UuidSchema })
  .strict();

export type KitchenTicketItemTransitionRequest = z.infer<
  typeof KitchenTicketItemTransitionRequestSchema
>;

// ---------------------------------------------------------------------------
// M4.3 — KDS read model
// ---------------------------------------------------------------------------

/**
 * Operational modifier snapshot for the KDS. Prices are intentionally omitted:
 * the kitchen display is not a financial surface.
 */
export const KitchenTicketModifierSchema = z
  .object({
    modifierGroupId: UuidSchema,
    modifierOptionId: UuidSchema,
    groupName: z.string().min(1).max(200),
    optionName: z.string().min(1).max(200),
  })
  .strict();

export type KitchenTicketModifier = z.infer<
  typeof KitchenTicketModifierSchema
>;

export const KitchenTicketBoardItemSchema = z
  .object({
    ticketItemId: UuidSchema,
    ticketId: UuidSchema,
    orderItemId: UuidSchema,
    menuItemId: UuidSchema,
    name: z.string().min(1).max(200),
    quantity: z.number().int().min(1).max(99),
    notes: z.string().max(500).nullable(),
    status: KitchenTicketStatusSchema,
    startedAt: NullableInstantSchema,
    readyAt: NullableInstantSchema,
    completedAt: NullableInstantSchema,
    cancelledAt: NullableInstantSchema,
    cancelledByActorType: KitchenCancellationActorTypeSchema,
    cancelledByStaffId: UuidSchema.nullable(),
    cancellationReason: NullableReasonSchema,
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
    modifiers: z.array(KitchenTicketModifierSchema),
  })
  .strict();

export type KitchenTicketBoardItem = z.infer<
  typeof KitchenTicketBoardItemSchema
>;

export const KitchenTicketOrderContextSchema = z
  .object({
    orderId: UuidSchema,
    orderReference: z.string().min(1).max(64),
    status: OrderStatusSchema,
    source: OrderSourceSchema,
    acceptedAt: NullableInstantSchema,
    notes: z.string().max(1000).nullable(),
    tableId: UuidSchema.nullable(),
    tableLabel: z.string().min(1).max(200).nullable(),
  })
  .strict();

export type KitchenTicketOrderContext = z.infer<
  typeof KitchenTicketOrderContextSchema
>;

/**
 * Complete KDS ticket view. It deliberately excludes every financial field
 * (prices, subtotals, discounts, totals, and payment data).
 */
export const KitchenTicketBoardSchema = z
  .object({
    ticketId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    stationId: UuidSchema,
    stationName: z.string().min(1).max(200),
    generation: z.number().int().min(1),
    status: KitchenTicketStatusSchema,
    startedAt: NullableInstantSchema,
    readyAt: NullableInstantSchema,
    completedAt: NullableInstantSchema,
    cancelledAt: NullableInstantSchema,
    cancelledByActorType: KitchenCancellationActorTypeSchema,
    cancelledByStaffId: UuidSchema.nullable(),
    cancellationReason: NullableReasonSchema,
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
    order: KitchenTicketOrderContextSchema,
    items: z.array(KitchenTicketBoardItemSchema),
  })
  .strict();

export type KitchenTicketBoard = z.infer<typeof KitchenTicketBoardSchema>;

export const ListKitchenTicketsRequestSchema = z
  .object({
    branchId: UuidSchema,
    stationId: UuidSchema.nullable().optional(),
    statuses: z
      .array(KitchenTicketStatusSchema)
      .min(1)
      .max(5)
      .optional(),
    limit: z.number().int().min(1).max(100).default(50),
    offset: z.number().int().min(0).default(0),
    from: UtcInstantSchema.nullable().optional(),
    to: UtcInstantSchema.nullable().optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    const historyStatuses = (value.statuses ?? []).filter(
      (status) => status === "completed" || status === "cancelled",
    );

    if (historyStatuses.length > 0 && (!value.from || !value.to)) {
      ctx.addIssue({
        code: "custom",
        path: ["from"],
        message:
          "History requests must include an explicit from/to time window",
      });
    }

    if (
      value.from &&
      value.to &&
      Date.parse(value.from) >= Date.parse(value.to)
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["to"],
        message: "The window start must precede the end",
      });
    }
  });

export type ListKitchenTicketsRequest = z.infer<
  typeof ListKitchenTicketsRequestSchema
>;

export const ListKitchenTicketsResponseSchema = z
  .object({
    branchId: UuidSchema,
    stationId: UuidSchema.nullable(),
    statuses: z.array(KitchenTicketStatusSchema).min(1).max(5),
    from: NullableInstantSchema,
    to: NullableInstantSchema,
    tickets: z.array(KitchenTicketBoardSchema),
    pageSize: z.number().int().min(1).max(100),
    hasMore: z.boolean(),
    nextOffset: z.number().int().min(0).nullable(),
  })
  .strict();

export type ListKitchenTicketsResponse = z.infer<
  typeof ListKitchenTicketsResponseSchema
>;

export const GetKitchenTicketRequestSchema = z
  .object({ ticketId: UuidSchema })
  .strict();

export type GetKitchenTicketRequest = z.infer<
  typeof GetKitchenTicketRequestSchema
>;

export const GetKitchenTicketResponseSchema = KitchenTicketBoardSchema;

export type GetKitchenTicketResponse = z.infer<
  typeof GetKitchenTicketResponseSchema
>;

// ---------------------------------------------------------------------------
// M4.3 — Station and routing management
// ---------------------------------------------------------------------------

export const KitchenStationStatusSchema = z.enum(["active", "inactive"]);

export type KitchenStationStatus = z.infer<
  typeof KitchenStationStatusSchema
>;

export const KitchenStationCategoryRouteSchema = z
  .object({
    routeId: UuidSchema,
    menuCategoryId: UuidSchema,
    menuCategoryName: z.string().min(1).max(200),
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
  })
  .strict();

export type KitchenStationCategoryRoute = z.infer<
  typeof KitchenStationCategoryRouteSchema
>;

export const KitchenStationItemRouteSchema = z
  .object({
    routeId: UuidSchema,
    menuItemId: UuidSchema,
    menuItemName: z.string().min(1).max(200),
    menuCategoryId: UuidSchema,
    menuCategoryName: z.string().min(1).max(200),
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
  })
  .strict();

export type KitchenStationItemRoute = z.infer<
  typeof KitchenStationItemRouteSchema
>;

export const KitchenStationSchema = z
  .object({
    stationId: UuidSchema,
    organizationId: UuidSchema,
    branchId: UuidSchema,
    name: z.string().min(1).max(200),
    description: z.string().max(1000).nullable(),
    status: KitchenStationStatusSchema,
    deactivatedAt: NullableInstantSchema,
    createdAt: UtcInstantSchema,
    updatedAt: UtcInstantSchema,
    categoryRoutes: z.array(KitchenStationCategoryRouteSchema),
    itemRoutes: z.array(KitchenStationItemRouteSchema),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.status === "inactive" && value.deactivatedAt === null) {
      ctx.addIssue({
        code: "custom",
        path: ["deactivatedAt"],
        message: "An inactive station requires a deactivation timestamp",
      });
    }

    if (value.status === "active" && value.deactivatedAt !== null) {
      ctx.addIssue({
        code: "custom",
        path: ["deactivatedAt"],
        message: "An active station cannot have a deactivation timestamp",
      });
    }
  });

export type KitchenStation = z.infer<typeof KitchenStationSchema>;

export const ListKitchenStationsRequestSchema = z
  .object({ branchId: UuidSchema })
  .strict();

export type ListKitchenStationsRequest = z.infer<
  typeof ListKitchenStationsRequestSchema
>;

export const ListKitchenStationsResponseSchema = z
  .object({
    branchId: UuidSchema,
    stations: z.array(KitchenStationSchema),
  })
  .strict();

export type ListKitchenStationsResponse = z.infer<
  typeof ListKitchenStationsResponseSchema
>;

export const CreateKitchenStationRequestSchema = z
  .object({
    branchId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    description: z.string().trim().max(1000).optional(),
  })
  .strict();

export type CreateKitchenStationRequest = z.infer<
  typeof CreateKitchenStationRequestSchema
>;

export const UpdateKitchenStationRequestSchema = z
  .object({
    stationId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    description: z.string().trim().max(1000).optional(),
  })
  .strict();

export type UpdateKitchenStationRequest = z.infer<
  typeof UpdateKitchenStationRequestSchema
>;

export const DeactivateKitchenStationRequestSchema = z
  .object({
    stationId: UuidSchema,
    reason: z.string().trim().max(500).optional(),
  })
  .strict();

export type DeactivateKitchenStationRequest = z.infer<
  typeof DeactivateKitchenStationRequestSchema
>;

export const ReactivateKitchenStationRequestSchema = z
  .object({ stationId: UuidSchema })
  .strict();

export type ReactivateKitchenStationRequest = z.infer<
  typeof ReactivateKitchenStationRequestSchema
>;

export const KitchenStationMutationResponseSchema = KitchenStationSchema;

export type KitchenStationMutationResponse = z.infer<
  typeof KitchenStationMutationResponseSchema
>;

export const AddKitchenStationCategoryRouteRequestSchema = z
  .object({
    stationId: UuidSchema,
    menuCategoryId: UuidSchema,
  })
  .strict();

export type AddKitchenStationCategoryRouteRequest = z.infer<
  typeof AddKitchenStationCategoryRouteRequestSchema
>;

export const RemoveKitchenStationCategoryRouteRequestSchema =
  AddKitchenStationCategoryRouteRequestSchema;

export type RemoveKitchenStationCategoryRouteRequest = z.infer<
  typeof RemoveKitchenStationCategoryRouteRequestSchema
>;

export const AddKitchenStationItemRouteRequestSchema = z
  .object({
    stationId: UuidSchema,
    menuItemId: UuidSchema,
  })
  .strict();

export type AddKitchenStationItemRouteRequest = z.infer<
  typeof AddKitchenStationItemRouteRequestSchema
>;

export const RemoveKitchenStationItemRouteRequestSchema =
  AddKitchenStationItemRouteRequestSchema;

export type RemoveKitchenStationItemRouteRequest = z.infer<
  typeof RemoveKitchenStationItemRouteRequestSchema
>;

// ---------------------------------------------------------------------------
// M4.3 — Realtime subscription contract
// ---------------------------------------------------------------------------

export const KDS_REALTIME_CHANNEL_PREFIX = "kds:branch:";

export const kdsRealtimeChannelName = (branchId: string): string =>
  `${KDS_REALTIME_CHANNEL_PREFIX}${branchId}`;

export const KdsRealtimeTableSchema = z.enum([
  "kitchen_tickets",
  "kitchen_ticket_items",
  "kitchen_stations",
  "kitchen_station_menu_items",
  "kitchen_station_menu_categories",
]);

export type KdsRealtimeTable = z.infer<typeof KdsRealtimeTableSchema>;

export const KdsRealtimeEventTypeSchema = z.enum([
  "INSERT",
  "UPDATE",
  "DELETE",
]);

export type KdsRealtimeEventType = z.infer<
  typeof KdsRealtimeEventTypeSchema
>;

/**
 * Branch-scoped KDS subscription. Channel names and filters are conveniences;
 * database RLS remains the authorization boundary.
 */
export const KdsRealtimeSubscriptionSchema = z
  .object({
    branchId: UuidSchema,
    channel: z
      .string()
      .min(1)
      .max(128)
      .regex(/^kds:branch:[0-9a-fA-F-]{36}$/),
    tables: z.array(KdsRealtimeTableSchema).min(1),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.channel !== kdsRealtimeChannelName(value.branchId)) {
      ctx.addIssue({
        code: "custom",
        path: ["channel"],
        message: "The channel must match the branch identifier",
      });
    }
  });

export type KdsRealtimeSubscription = z.infer<
  typeof KdsRealtimeSubscriptionSchema
>;

/**
 * Normalized notification shape. Clients must refetch authoritative state
 * through the KDS read RPC after receiving a notification. Raw Postgres rows
 * are intentionally typed as unknown values.
 */
export const KdsRealtimeNotificationSchema = z
  .object({
    table: KdsRealtimeTableSchema,
    eventType: KdsRealtimeEventTypeSchema,
    branchId: UuidSchema,
    record: z.record(z.string(), z.unknown()).nullable(),
    oldRecord: z.record(z.string(), z.unknown()).nullable(),
  })
  .strict();

export type KdsRealtimeNotification = z.infer<
  typeof KdsRealtimeNotificationSchema
>;
