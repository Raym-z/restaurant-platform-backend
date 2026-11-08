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
  return new Response(JSON.stringify(body), { status, headers });
};

export const readJsonBody = async (request: Request): Promise<unknown> => {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    const parsed = Number.parseInt(contentLength, 10);
    if (Number.isFinite(parsed) && parsed > MAX_BODY_BYTES) {
      throw new AppError("VALIDATION_ERROR", "Request body is too large");
    }
  }

  try {
    return await request.json();
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
    return jsonResponse(
      apiFailure(error.toPayload()),
      error.httpStatus,
      request,
      env,
    );
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
