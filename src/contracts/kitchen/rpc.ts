import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { UtcInstantSchema } from "../common/time.ts";

const NullableInstantSchema = UtcInstantSchema.nullable();

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
