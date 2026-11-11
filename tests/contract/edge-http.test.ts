import { describe, expect, it } from "vitest";

import { AppError } from "../../src/lib/errors.ts";
import {
  MAX_BODY_BYTES,
  errorResponse,
  readJsonBody,
} from "../../supabase/functions/_shared/http.ts";

const env = {
  supabaseUrl: "http://127.0.0.1:54321",
  serviceRoleKey: "test-only-placeholder",
  guestTokenTtlSeconds: 60,
  corsAllowedOrigins: ["*"],
  rateLimitHashSecret: "a".repeat(32),
  trustedClientIpHeader: null,
  trustedProxyHops: 0,
};

describe("Edge HTTP hardening", () => {
  it("rejects oversized bodies even without content-length", async () => {
    const body = "x".repeat(MAX_BODY_BYTES + 1);
    const request = new Request("http://127.0.0.1/guest", {
      method: "POST",
      body,
      headers: { "content-type": "text/plain" },
    });

    expect(request.headers.get("content-length")).toBeNull();

    await expect(readJsonBody(request)).rejects.toMatchObject({
      code: "VALIDATION_ERROR",
    });
  });

  it("adds Retry-After for rate-limit errors", () => {
    const request = new Request("http://127.0.0.1/guest", { method: "POST" });
    const response = errorResponse(
      new AppError("RATE_LIMIT_EXCEEDED", "Too many requests", {
        retryAfterSeconds: 42,
      }),
      request,
      env,
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("42");
  });

  it("does not add Retry-After to unrelated errors", () => {
    const request = new Request("http://127.0.0.1/guest", { method: "POST" });
    const response = errorResponse(
      new AppError("VALIDATION_ERROR", "Invalid request"),
      request,
      env,
    );

    expect(response.status).toBe(400);
    expect(response.headers.get("Retry-After")).toBeNull();
  });
});
