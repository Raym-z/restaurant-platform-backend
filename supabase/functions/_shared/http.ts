import { ZodError } from "zod";

import {
  apiFailure,
  apiSuccess,
  type ApiMeta,
} from "../../../src/contracts/common/api-response.ts";
import { toValidationIssues } from "../../../src/contracts/common/validation.ts";
import {
  AppError,
  HTTP_STATUS_BY_ERROR_CODE,
} from "../../../src/lib/errors.ts";
import type { EdgeEnv } from "./env.ts";

export const MAX_BODY_BYTES = 1_000_000;

export const corsHeaders = (request: Request, env: EdgeEnv | null): Headers => {
  const headers = new Headers();
  const origin = request.headers.get("origin");
  const allowed = env?.corsAllowedOrigins ?? ["*"];

  if (allowed.includes("*")) {
    headers.set("Access-Control-Allow-Origin", "*");
  } else if (origin !== null && allowed.includes(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Vary", "Origin");
  }

  headers.set(
    "Access-Control-Allow-Headers",
    "authorization, x-client-info, apikey, content-type, idempotency-key",
  );
  headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  headers.set("Access-Control-Max-Age", "86400");
  return headers;
};

export const optionsResponse = (request: Request, env: EdgeEnv): Response =>
  new Response(null, {
    status: 204,
    headers: corsHeaders(request, env),
  });

export const jsonResponse = (
  body: unknown,
  status: number,
  request: Request,
  env: EdgeEnv | null,
): Response => {
  const headers = corsHeaders(request, env);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(JSON.stringify(body), { status, headers });
};

export const readJsonBody = async (request: Request): Promise<unknown> => {
  if (request.body === null) {
    throw new AppError("VALIDATION_ERROR", "Request body is required");
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;

  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value === undefined) continue;

      received += value.byteLength;
      if (received > MAX_BODY_BYTES) {
        await reader.cancel();
        throw new AppError("VALIDATION_ERROR", "Request body is too large");
      }

      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new AppError("VALIDATION_ERROR", "Request body must be valid JSON");
  }
};

export const successResponse = <T>(
  data: T,
  request: Request,
  env: EdgeEnv,
  status = 200,
  meta: ApiMeta = null,
): Response => jsonResponse(apiSuccess(data, meta), status, request, env);

export const errorResponse = (
  error: unknown,
  request: Request,
  env: EdgeEnv | null,
): Response => {
  if (error instanceof AppError) {
    const response = jsonResponse(
      apiFailure(error.toPayload()),
      error.httpStatus,
      request,
      env,
    );

    if (error.code === "RATE_LIMIT_EXCEEDED") {
      const retryAfter = error.details?.retryAfterSeconds;
      if (typeof retryAfter === "number" && Number.isFinite(retryAfter)) {
        response.headers.set(
          "Retry-After",
          String(Math.max(1, Math.ceil(retryAfter))),
        );
      }
    }

    return response;
  }

  if (error instanceof ZodError) {
    return jsonResponse(
      apiFailure({
        code: "VALIDATION_ERROR",
        message: "Request validation failed",
        details: { issues: toValidationIssues(error) },
      }),
      400,
      request,
      env,
    );
  }

  return jsonResponse(
    apiFailure({
      code: "INTERNAL_ERROR",
      message: "An unexpected error occurred.",
      details: null,
    }),
    HTTP_STATUS_BY_ERROR_CODE.INTERNAL_ERROR,
    request,
    env,
  );
};
