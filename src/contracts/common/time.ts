import { z } from "zod";

/**
 * ISO-8601 UTC timestamp with a trailing `Z`. Persisted instants use
 * `timestamptz`; branch-local dates are represented separately.
 */
export const UTC_INSTANT_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/;

export const UtcInstantSchema = z
  .string()
  .regex(UTC_INSTANT_PATTERN, "Must be an ISO-8601 UTC timestamp ending in Z");

export type UtcInstant = z.infer<typeof UtcInstantSchema>;

export const BRANCH_LOCAL_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export const BranchLocalDateSchema = z
  .string()
  .regex(BRANCH_LOCAL_DATE_PATTERN, "Must be an ISO-8601 calendar date");

export type BranchLocalDate = z.infer<typeof BranchLocalDateSchema>;

/**
 * IANA timezone name, for example `Asia/Jakarta`. The database remains the
 * authority for accepted timezone values.
 */
export const IANA_TIMEZONE_PATTERN =
  /^(?:UTC|[A-Za-z_]+(?:\/[A-Za-z0-9_+\-]+)+)$/;

export const IanaTimezoneSchema = z
  .string()
  .min(1)
  .max(64)
  .regex(IANA_TIMEZONE_PATTERN, "Must be a valid IANA timezone name");

export type IanaTimezone = z.infer<typeof IanaTimezoneSchema>;

export const isUtcInstant = (value: string): boolean =>
  UTC_INSTANT_PATTERN.test(value);
