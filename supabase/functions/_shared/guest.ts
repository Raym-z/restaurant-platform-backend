import {
  GuestSessionContextSchema,
  type GuestSessionContext,
} from "../../../src/contracts/guest/session.ts";
import { AppError } from "../../../src/lib/errors.ts";

/**
 * Map the trusted RPC response into the public guest-session contract. The RPC
 * also returns token expiry; that is returned separately by resolve-table.
 */
export const toGuestSessionContext = (
  data: Record<string, unknown>,
): GuestSessionContext => {
  try {
    return GuestSessionContextSchema.parse({
      sessionId: data.sessionId,
      organizationId: data.organizationId,
      branchId: data.branchId,
      tableId: data.tableId,
      tableLabel: data.tableLabel,
      branchName: data.branchName,
      timezone: data.timezone,
      currency: data.currency,
      status: data.status,
      openedAt: data.openedAt,
    });
  } catch {
    throw new AppError(
      "INTERNAL_ERROR",
      "Backend returned an invalid guest session context",
    );
  }
};
