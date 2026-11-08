import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { getEdgeEnv } from "./env.ts";

export const createServiceClient = (): SupabaseClient => {
  const env = getEdgeEnv();

  return createClient(env.supabaseUrl, env.serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
};
