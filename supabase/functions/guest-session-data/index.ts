import { apiFailure } from "../../../src/contracts/common/api-response.ts";
import {
  GuestOrderSummarySchema,
  GuestSessionDataRequestSchema,
  GuestSessionDataResponseSchema,
} from "../../../src/contracts/guest/session.ts";
import type { EdgeEnv } from "../_shared/env.ts";
import { getEdgeEnv } from "../_shared/env.ts";
import { toGuestSessionContext } from "../_shared/guest.ts";
import {
  errorResponse,
  jsonResponse,
  optionsResponse,
  readJsonBody,
  successResponse,
} from "../_shared/http.ts";
import { enforceRateLimit, getClientBucketKey } from "../_shared/rateLimit.ts";
import { callRpc } from "../_shared/rpc.ts";
import { createServiceClient } from "../_shared/supabase.ts";
import { sha256Hex } from "../_shared/token.ts";

Deno.serve(async (request: Request, info): Promise<Response> => {
  let env: EdgeEnv | null = null;

  try {
    env = getEdgeEnv();

    if (request.method === "OPTIONS") {
      return optionsResponse(request, env);
    }

    if (request.method !== "POST") {
      return jsonResponse(
        apiFailure({
          code: "VALIDATION_ERROR",
          message: "Only POST is supported",
        }),
        405,
        request,
        env,
      );
    }

    const input = GuestSessionDataRequestSchema.parse(
      await readJsonBody(request),
    );
    const tokenHash = await sha256Hex(input.guestToken);
    const client = createServiceClient();

    const clientBucket = await getClientBucketKey(request, info, env);
    await enforceRateLimit(client, "guest_session_ip", clientBucket);
    await enforceRateLimit(client, "guest_token", tokenHash);

    const data = await callRpc<Record<string, unknown>>(
      client,
      "get_guest_session_data",
      { p_token_hash_hex: tokenHash },
    );

    const session = toGuestSessionContext(
      data.session as Record<string, unknown>,
    );
    const orders = GuestOrderSummarySchema.array().parse(data.orders);

    const response = GuestSessionDataResponseSchema.parse({
      session,
      orders,
    });

    return successResponse(response, request, env);
  } catch (error) {
    return errorResponse(error, request, env);
  }
});
