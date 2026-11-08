import type { SupabaseClient } from "@supabase/supabase-js";

import { AppError } from "../../../src/lib/errors.ts";
import { ipBucketValue, keyedHash, selectClientIp } from "./clientIdentity.ts";
import type { EdgeEnv } from "./env.ts";
import { callRpc } from "./rpc.ts";

export type RateLimitResult = {
  allowed: boolean;
  limit: number;
  remaining: number;
  retryAfterSeconds: number;
  resetAt: string;
};

export type ConnectionInfo = {
  remoteAddr?: {
    hostname?: string;
  };
} | null;

/**
 * Build a privacy-preserving IP bucket. The raw IP is never stored; it is
 * normalized, HMAC-hashed with a server secret, and prefixed for readability.
 */
export const getClientBucketKey = async (
  request: Request,
  info: ConnectionInfo,
  env: EdgeEnv,
): Promise<string> => {
  const identity = selectClientIp({
    headers: request.headers,
    peerAddress: info?.remoteAddr?.hostname ?? null,
    config: {
      trustedHeader: env.trustedClientIpHeader,
      trustedProxyHops: env.trustedProxyHops,
    },
  });

  const digest = await keyedHash(
    env.rateLimitHashSecret,
    ipBucketValue(identity),
  );
  return `ip:${digest}`;
};

/**
 * Consume one attempt from a server-side policy. The suffix must never contain
 * a raw guest token; callers pass a hashed IP, QR UUID, customer ID, or token
 * hash.
 */
export const enforceRateLimit = async (
  client: SupabaseClient,
  policy: string,
  bucketSuffix: string,
): Promise<RateLimitResult> => {
  const data = await callRpc<Record<string, unknown>>(
    client,
    "consume_rate_limit",
    {
      p_policy: policy,
      p_bucket_suffix: bucketSuffix,
    },
  );

  const allowed = data.allowed === true;
  const limit = typeof data.limit === "number" ? data.limit : 0;
  const remaining = typeof data.remaining === "number" ? data.remaining : 0;
  const retryAfterSeconds =
    typeof data.retryAfterSeconds === "number" ? data.retryAfterSeconds : 60;
  const resetAt = typeof data.resetAt === "string" ? data.resetAt : "";

  if (!allowed) {
    throw new AppError("RATE_LIMIT_EXCEEDED", "Too many requests", {
      retryAfterSeconds,
    });
  }

  return { allowed, limit, remaining, retryAfterSeconds, resetAt };
};
