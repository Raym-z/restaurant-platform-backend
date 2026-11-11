import { AppError } from "../../../src/lib/errors.ts";
import { isTrustedIpHeader } from "./clientIdentity.ts";

export type EdgeEnv = {
  supabaseUrl: string;
  serviceRoleKey: string;
  guestTokenTtlSeconds: number;
  corsAllowedOrigins: string[];
  rateLimitHashSecret: string;
  trustedClientIpHeader: string | null;
  trustedProxyHops: number;
};

let cached: EdgeEnv | null = null;

const required = (name: string): string => {
  const value = Deno.env.get(name);
  if (value === undefined || value.trim() === "") {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      `Required server configuration ${name} is missing`,
    );
  }
  return value;
};

export type StaffInviteEnv = {
  supabaseUrl: string;
  serviceRoleKey: string;
  anonKey: string;
  acceptanceUrl: string;
  invitationTtlSeconds: number;
  corsAllowedOrigins: string[];
};

let cachedStaffInvite: StaffInviteEnv | null = null;

const corsOrigins = (): string[] => {
  const origins = (Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "*")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  return origins.length > 0 ? origins : ["*"];
};

export const getEdgeEnv = (): EdgeEnv => {
  if (cached !== null) {
    return cached;
  }

  const ttlRaw = required("GUEST_TOKEN_TTL_SECONDS");
  const ttl = Number.parseInt(ttlRaw, 10);

  if (!Number.isInteger(ttl) || ttl <= 0) {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "GUEST_TOKEN_TTL_SECONDS must be a positive integer",
    );
  }

  const hashSecret = required("RATE_LIMIT_HASH_SECRET");
  if (hashSecret.length < 32) {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "RATE_LIMIT_HASH_SECRET must be at least 32 characters",
    );
  }

  const headerRaw = Deno.env.get("TRUSTED_CLIENT_IP_HEADER");
  const trustedHeader =
    headerRaw === undefined || headerRaw.trim() === ""
      ? null
      : headerRaw.trim().toLowerCase();

  if (trustedHeader !== null && !isTrustedIpHeader(trustedHeader)) {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "TRUSTED_CLIENT_IP_HEADER is not a supported header",
    );
  }

  const hopsRaw = Deno.env.get("TRUSTED_PROXY_HOPS") ?? "1";
  const hops = Number.parseInt(hopsRaw, 10);

  if (trustedHeader !== null && (!Number.isInteger(hops) || hops < 1)) {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "TRUSTED_PROXY_HOPS must be a positive integer",
    );
  }

  const origins = (Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "*")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  cached = {
    supabaseUrl: required("SUPABASE_URL"),
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    guestTokenTtlSeconds: ttl,
    corsAllowedOrigins: origins.length > 0 ? origins : ["*"],
    rateLimitHashSecret: hashSecret,
    trustedClientIpHeader: trustedHeader,
    trustedProxyHops: trustedHeader === null ? 0 : hops,
  };

  return cached;
};

/**
 * Environment for the staff invitation function.
 *
 * This intentionally does not require guest-only secrets so the invitation
 * function can be deployed without enabling guest flows.
 */
export const getStaffInviteEnv = (): StaffInviteEnv => {
  if (cachedStaffInvite !== null) {
    return cachedStaffInvite;
  }

  const acceptanceUrl = required("POS_ACCEPT_INVITATION_URL");

  let parsedAcceptanceUrl: URL;
  try {
    parsedAcceptanceUrl = new URL(acceptanceUrl);
  } catch {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "POS_ACCEPT_INVITATION_URL must be an absolute URL",
    );
  }

  if (!["http:", "https:"].includes(parsedAcceptanceUrl.protocol)) {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "POS_ACCEPT_INVITATION_URL must use http or https",
    );
  }

  const ttlRaw = Deno.env.get("STAFF_INVITATION_TTL_SECONDS") ?? "604800";
  const ttl = Number.parseInt(ttlRaw, 10);

  if (!Number.isInteger(ttl) || ttl < 300 || ttl > 2_592_000) {
    throw new AppError(
      "SERVICE_UNAVAILABLE",
      "STAFF_INVITATION_TTL_SECONDS must be between 300 and 2592000",
    );
  }

  cachedStaffInvite = {
    supabaseUrl: required("SUPABASE_URL"),
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    anonKey:
      Deno.env.get("SUPABASE_ANON_KEY")?.trim() ||
      required("SUPABASE_PUBLISHABLE_KEY"),
    acceptanceUrl: parsedAcceptanceUrl.toString(),
    invitationTtlSeconds: ttl,
    corsAllowedOrigins: corsOrigins(),
  };

  return cachedStaffInvite;
};
