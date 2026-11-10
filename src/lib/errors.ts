import type {
  ApiErrorCode,
  ApiErrorPayload,
} from "../contracts/common/errors.ts";

/**
 * HTTP status mapping for the canonical API error catalog. Edge Functions and
 * API adapters use this mapping; RPC errors are translated into the same
 * payload shape before being returned to clients.
 */
export const HTTP_STATUS_BY_ERROR_CODE: Record<ApiErrorCode, number> = {
  AUTH_REQUIRED: 401,
  AUTH_INVALID_TOKEN: 401,
  AUTH_SESSION_EXPIRED: 401,
  AUTH_ACCOUNT_INACTIVE: 403,

  PERMISSION_DENIED: 403,
  ORGANIZATION_ACCESS_DENIED: 403,
  BRANCH_ACCESS_DENIED: 403,
  ROLE_REQUIRED: 403,

  ORGANIZATION_NOT_FOUND: 404,
  ORGANIZATION_ALREADY_EXISTS: 409,
  ORGANIZATION_DELETION_PENDING: 409,
  ORGANIZATION_NOT_OPERATIONAL: 422,
  BRANCH_NOT_FOUND: 404,
  BRANCH_LIMIT_REACHED: 422,
  BRANCH_ALREADY_EXISTS: 409,

  SUBSCRIPTION_RESTRICTED: 422,
  SUBSCRIPTION_EXPIRED: 422,
  SUBSCRIPTION_PERMISSION_DENIED: 403,
  SUBSCRIPTION_LIMIT_REACHED: 422,
  SUBSCRIPTION_PLAN_UNAVAILABLE: 422,

  MENU_ITEM_NOT_FOUND: 404,
  MENU_ITEM_UNAVAILABLE: 422,
  INVALID_MENU_PRICE: 422,
  INVALID_MODIFIER_SELECTION: 422,

  TABLE_NOT_FOUND: 404,
  TABLE_QR_INVALID: 404,
  GUEST_TOKEN_INVALID: 401,
  GUEST_TOKEN_EXPIRED: 401,
  GUEST_TOKEN_REVOKED: 401,
  GUEST_SESSION_CLOSED: 409,
  GUEST_SESSION_NOT_FOUND: 404,

  ORDER_NOT_FOUND: 404,
  ORDER_INVALID_STATUS: 409,
  ORDER_SUBMISSION_FAILED: 422,
  ORDER_ALREADY_PROCESSED: 409,
  ORDER_ITEM_UNAVAILABLE: 422,
  ORDER_ITEM_NOT_FOUND: 404,
  ORDER_MODIFICATION_NOT_ALLOWED: 422,
  ORDER_EMPTY: 400,
  ORDER_ITEM_QUANTITY_INVALID: 400,

  KITCHEN_TICKET_NOT_FOUND: 404,
  KITCHEN_TICKET_ITEM_NOT_FOUND: 404,
  KITCHEN_INVALID_TRANSITION: 409,
  KITCHEN_TICKET_CANCELLED: 409,
  KITCHEN_TICKET_INCONSISTENT: 409,
  KITCHEN_CANCELLATION_INVALID: 422,
  KITCHEN_STATION_NOT_FOUND: 404,
  KITCHEN_STATION_INACTIVE: 409,

  BILL_NOT_FOUND: 404,
  BILL_ALREADY_FINALIZED: 409,
  BILL_REOPEN_NOT_ALLOWED: 422,
  BILL_NOT_FINALIZED: 422,
  BILL_ALREADY_SETTLED: 409,
  PAYMENT_ALREADY_RECORDED: 409,
  PAYMENT_AMOUNT_INVALID: 422,
  PAYMENT_METHOD_NOT_SUPPORTED: 422,
  PAYMENT_BILL_MISMATCH: 422,
  SESSION_NOT_SETTLED: 422,

  WAITLIST_ENTRY_NOT_FOUND: 404,
  WAITLIST_ENTRY_ALREADY_EXISTS: 409,
  WAITLIST_INVALID_STATUS: 409,
  WAITLIST_LOCATION_REQUIRED: 422,
  WAITLIST_DISTANCE_EXCEEDED: 422,
  WAITLIST_INVALID_TRANSITION: 409,
  WAITLIST_POSITION_CONFLICT: 409,

  STAFF_NOT_FOUND: 404,
  STAFF_NOT_ACTIVE: 403,
  STAFF_ALREADY_MEMBER: 409,
  LAST_OWNER_PROTECTED: 409,

  DINING_SESSION_NOT_FOUND: 404,
  SESSION_NOT_ACTIVE: 409,
  SESSION_ALREADY_CLOSED: 409,
  SESSION_BALANCE_OUTSTANDING: 422,

  VALIDATION_ERROR: 400,
  RESOURCE_CONFLICT: 409,
  RATE_LIMIT_EXCEEDED: 429,
  IDEMPOTENCY_CONFLICT: 409,
  IDEMPOTENCY_IN_PROGRESS: 409,
  PLATFORM_ACCESS_DENIED: 403,
  EXCEPTIONAL_ACCESS_EXPIRED: 403,
  SERVICE_UNAVAILABLE: 503,
  INTERNAL_ERROR: 500,
};

/**
 * Typed application error used at trusted backend boundaries. The message is
 * safe to return to clients; internal diagnostics belong in server logs.
 */
export class AppError extends Error {
  readonly code: ApiErrorCode;

  readonly details: ApiErrorPayload["details"];

  constructor(
    code: ApiErrorCode,
    message: string,
    details: ApiErrorPayload["details"] = null,
  ) {
    super(message);
    this.name = "AppError";
    this.code = code;
    this.details = details;
  }

  get httpStatus(): number {
    return HTTP_STATUS_BY_ERROR_CODE[this.code];
  }

  toPayload(): ApiErrorPayload {
    return {
      code: this.code,
      message: this.message,
      details: this.details,
    };
  }
}

export const isAppError = (error: unknown): error is AppError =>
  error instanceof AppError;

/**
 * Convert an unknown thrown value into a safe client payload. Unexpected
 * errors never expose internal details.
 */
export const toApiErrorPayload = (
  error: unknown,
  fallbackCode: ApiErrorCode = "INTERNAL_ERROR",
): ApiErrorPayload => {
  if (isAppError(error)) {
    return error.toPayload();
  }

  return {
    code: fallbackCode,
    message: "An unexpected error occurred.",
    details: null,
  };
};
