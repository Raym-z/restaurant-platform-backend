import { AppError } from "../../../src/lib/errors.ts";

export type EdgeEnv = {
  supabaseUrl: string;
  serviceRoleKey: string;
  guestTokenTtlSeconds: number;
  corsAllowedOrigins: string[];
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

  const origins = (Deno.env.get("CORS_ALLOWED_ORIGINS") ?? "*")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  cached = {
    supabaseUrl: required("SUPABASE_URL"),
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    guestTokenTtlSeconds: ttl,
    corsAllowedOrigins: origins.length > 0 ? origins : ["*"],
  };

  return cached;
};
