import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { getEdgeEnv, getStaffInviteEnv } from "./env.ts";

const baseOptions = {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
} as const;

export const createServiceClient = (): SupabaseClient => {
  const env = getEdgeEnv();

  return createClient(env.supabaseUrl, env.serviceRoleKey, baseOptions);
};

export const createStaffServiceClient = (): SupabaseClient => {
  const env = getStaffInviteEnv();

  return createClient(env.supabaseUrl, env.serviceRoleKey, baseOptions);
};

export const createStaffAnonClient = (): SupabaseClient => {
  const env = getStaffInviteEnv();

  return createClient(env.supabaseUrl, env.anonKey, baseOptions);
};

/**
 * Request-scoped client that carries the caller's bearer token. Database RPCs
 * invoked through this client run as the authenticated staff member, so all
 * organization, role, and branch authorization remains server-enforced.
 */
export const createStaffUserClient = (accessToken: string): SupabaseClient => {
  const env = getStaffInviteEnv();

  return createClient(env.supabaseUrl, env.anonKey, {
    ...baseOptions,
    global: {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
  });
};
