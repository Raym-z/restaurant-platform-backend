import type { SupabaseClient } from "@supabase/supabase-js";

import { isApiErrorCode } from "../../../src/contracts/common/errors.ts";
import { AppError } from "../../../src/lib/errors.ts";

export const callRpc = async <T>(
  client: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<T> => {
  const { data, error } = await client.rpc(functionName, args);

  if (error !== null) {
    const code = isApiErrorCode(error.message)
      ? error.message
      : "INTERNAL_ERROR";

    const detail =
      typeof error.details === "string" && error.details.length > 0
        ? error.details
        : "Backend operation failed";

    throw new AppError(
      code,
      code === "INTERNAL_ERROR" ? "Backend operation failed" : detail,
      typeof error.details === "string" && error.details.length > 0
        ? { detail: error.details }
        : null,
    );
  }

  return data as T;
};
