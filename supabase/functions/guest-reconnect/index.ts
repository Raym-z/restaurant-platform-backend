import { apiFailure } from "../../../src/contracts/common/api-response.ts";
import {
  GuestReconnectRequestSchema,
  GuestSessionResponseSchema,
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
import { callRpc } from "../_shared/rpc.ts";
import { createServiceClient } from "../_shared/supabase.ts";
import { sha256Hex } from "../_shared/token.ts";

Deno.serve(async (request: Request): Promise<Response> => {
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

    const input = GuestReconnectRequestSchema.parse(
      await readJsonBody(request),
    );
    const tokenHash = await sha256Hex(input.guestToken);

    const client = createServiceClient();
    const data = await callRpc<Record<string, unknown>>(
      client,
      "validate_guest_token",
      { p_token_hash_hex: tokenHash },
    );

    const response = GuestSessionResponseSchema.parse({
      session: toGuestSessionContext(data),
    });

    return successResponse(response, request, env);
  } catch (error) {
    return errorResponse(error, request, env);
  }
});
