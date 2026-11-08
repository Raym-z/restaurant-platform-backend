import { z } from "zod";

/**
 * Persisted subscription lifecycle. Free organizations are represented by the
 * plan, not by a subscription status.
 */
export const SubscriptionStatusSchema = z.enum([
  "active",
  "expired",
  "grace_period",
  "restricted",
]);

export type SubscriptionStatus = z.infer<typeof SubscriptionStatusSchema>;

/**
 * Effective operational state used by backend authorization gates.
 */
export const OrganizationOperationalStateSchema = z.enum([
  "active",
  "grace",
  "restricted",
  "deletion_pending",
  "suspended",
  "free",
]);

export type OrganizationOperationalState = z.infer<
  typeof OrganizationOperationalStateSchema
>;
