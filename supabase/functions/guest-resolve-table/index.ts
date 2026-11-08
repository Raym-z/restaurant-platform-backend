import { apiFailure } from "../../../src/contracts/common/api-response.ts";
import {
  ResolveTableRequestSchema,
  ResolveTableResponseSchema,
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
import { generateGuestToken, sha256Hex } from "../_shared/token.ts";

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

    const input = ResolveTableRequestSchema.parse(await readJsonBody(request));
    const guestToken = generateGuestToken();
    const tokenHash = await sha256Hex(guestToken);
    const tokenExpiresAt = new Date(
      Date.now() + env.guestTokenTtlSeconds * 1000,
    ).toISOString();

    const client = createServiceClient();
    const data = await callRpc<Record<string, unknown>>(
      client,
      "resolve_or_create_dining_session",
      {
        p_qr_public_id: input.qrIdentifier,
        p_token_hash_hex: tokenHash,
        p_device_label: input.deviceLabel ?? null,
        p_expires_at: tokenExpiresAt,
      },
    );

    const response = ResolveTableResponseSchema.parse({
      session: toGuestSessionContext(data),
      guestToken,
      tokenExpiresAt,
    });

    return successResponse(response, request, env);
  } catch (error) {
    return errorResponse(error, request, env);
  }
});
