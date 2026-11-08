import { z } from "zod";

/**
 * Canonical API error codes.
 *
 * These codes are shared by Edge Functions, RPC wrappers, and consuming
 * applications. Additions are coordinated changes: do not remove or rename a
 * published code without a contract update.
 */
export const API_ERROR_CODES = [
  // Authentication
  "AUTH_REQUIRED",
  "AUTH_INVALID_TOKEN",
  "AUTH_SESSION_EXPIRED",
  "AUTH_ACCOUNT_INACTIVE",

  // Authorization
  "PERMISSION_DENIED",
  "ORGANIZATION_ACCESS_DENIED",
  "BRANCH_ACCESS_DENIED",
  "ROLE_REQUIRED",

  // Organization and branch
  "ORGANIZATION_NOT_FOUND",
  "ORGANIZATION_ALREADY_EXISTS",
  "ORGANIZATION_DELETION_PENDING",
  "ORGANIZATION_NOT_OPERATIONAL",
  "BRANCH_NOT_FOUND",
  "BRANCH_LIMIT_REACHED",
  "BRANCH_ALREADY_EXISTS",

  // Subscription
  "SUBSCRIPTION_RESTRICTED",
  "SUBSCRIPTION_EXPIRED",
  "SUBSCRIPTION_PERMISSION_DENIED",
  "SUBSCRIPTION_LIMIT_REACHED",
  "SUBSCRIPTION_PLAN_UNAVAILABLE",

  // Menu
  "MENU_ITEM_NOT_FOUND",
  "MENU_ITEM_UNAVAILABLE",
  "INVALID_MENU_PRICE",
  "INVALID_MODIFIER_SELECTION",

  // Tables and guest sessions
  "TABLE_NOT_FOUND",
  "TABLE_QR_INVALID",
  "GUEST_TOKEN_INVALID",
  "GUEST_TOKEN_EXPIRED",
  "GUEST_TOKEN_REVOKED",
  "GUEST_SESSION_CLOSED",
  "GUEST_SESSION_NOT_FOUND",

  // Orders
  "ORDER_NOT_FOUND",
  "ORDER_INVALID_STATUS",
  "ORDER_SUBMISSION_FAILED",
  "ORDER_ALREADY_PROCESSED",
  "ORDER_ITEM_UNAVAILABLE",
  "ORDER_ITEM_NOT_FOUND",
  "ORDER_MODIFICATION_NOT_ALLOWED",
  "ORDER_EMPTY",
  "ORDER_ITEM_QUANTITY_INVALID",

  // Billing and payments
  "BILL_NOT_FOUND",
  "BILL_ALREADY_FINALIZED",
  "BILL_REOPEN_NOT_ALLOWED",
  "BILL_NOT_FINALIZED",
  "BILL_ALREADY_SETTLED",
  "PAYMENT_ALREADY_RECORDED",
  "PAYMENT_AMOUNT_INVALID",
  "PAYMENT_METHOD_NOT_SUPPORTED",
  "PAYMENT_BILL_MISMATCH",
  "SESSION_NOT_SETTLED",

  // Waitlist
  "WAITLIST_ENTRY_NOT_FOUND",
  "WAITLIST_ENTRY_ALREADY_EXISTS",
  "WAITLIST_INVALID_STATUS",
  "WAITLIST_LOCATION_REQUIRED",
  "WAITLIST_DISTANCE_EXCEEDED",
  "WAITLIST_INVALID_TRANSITION",
  "WAITLIST_POSITION_CONFLICT",

  // Staff
  "STAFF_NOT_FOUND",
  "STAFF_NOT_ACTIVE",
  "STAFF_ALREADY_MEMBER",
  "LAST_OWNER_PROTECTED",

  // Dining sessions
  "DINING_SESSION_NOT_FOUND",
  "SESSION_NOT_ACTIVE",
  "SESSION_ALREADY_CLOSED",
  "SESSION_BALANCE_OUTSTANDING",

  // General
  "VALIDATION_ERROR",
  "RESOURCE_CONFLICT",
  "RATE_LIMIT_EXCEEDED",
  "IDEMPOTENCY_CONFLICT",
  "IDEMPOTENCY_IN_PROGRESS",
  "PLATFORM_ACCESS_DENIED",
  "EXCEPTIONAL_ACCESS_EXPIRED",
  "SERVICE_UNAVAILABLE",
  "INTERNAL_ERROR",
] as const;

export type ApiErrorCode = (typeof API_ERROR_CODES)[number];

export const ApiErrorCodeSchema = z.enum(API_ERROR_CODES);

export const ApiErrorDetailsSchema = z
  .record(z.string(), z.unknown())
  .nullable();

export const ApiErrorPayloadSchema = z
  .object({
    code: ApiErrorCodeSchema,
    message: z.string().min(1).max(500),
    details: ApiErrorDetailsSchema.default(null),
  })
  .strict();

export type ApiErrorPayload = z.infer<typeof ApiErrorPayloadSchema>;

export const isApiErrorCode = (value: unknown): value is ApiErrorCode =>
  typeof value === "string" &&
  (API_ERROR_CODES as readonly string[]).includes(value);
