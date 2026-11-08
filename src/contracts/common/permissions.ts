import { z } from "zod";

/**
 * Permission keys are intentionally opaque to the contract layer. The approved
 * role-to-permission mapping is maintained separately; this package does not
 * grant, seed, or imply any permission.
 *
 * Conventional shape: `<domain>.<resource>.<action>`.
 */
export const PermissionKeySchema = z
  .string()
  .min(3)
  .max(120)
  .regex(
    /^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$/,
    "Must be a dotted lowercase permission key",
  );

export type PermissionKey = z.infer<typeof PermissionKeySchema>;
