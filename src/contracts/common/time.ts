import { z } from "zod";

/**
 * Strict ISO-8601 instant with a trailing `Z` or numeric UTC offset.
 *
 * PostgreSQL/PostgREST serializes `timestamptz` with an offset (for example
 * `+00:00` or the database session offset), not necessarily `Z`. The parser
 * validates real calendar dates/times and normalizes the result to UTC `Z`
 * with microsecond precision (six fractional digits).
 */
export const ISO_INSTANT_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|([+-])(\d{2}):(\d{2}))$/;

const pad = (value: number, length: number): string =>
  String(value).padStart(length, "0");

const daysInMonth = (year: number, month: number): number => {
  if (month === 2) {
    const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
    return leap ? 29 : 28;
  }

  return [4, 6, 9, 11].includes(month) ? 30 : 31;
};

export const normalizeUtcInstant = (value: string): string | null => {
  const match = ISO_INSTANT_PATTERN.exec(value);
  if (match === null) {
    return null;
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const fraction = match[7] ?? "";
  const offsetHours = match[10] === undefined ? 0 : Number(match[10]);
  const offsetMinutes = match[11] === undefined ? 0 : Number(match[11]);

  if (
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth(year, month) ||
    hour > 23 ||
    minute > 59 ||
    second > 59
  ) {
    return null;
  }

  if (offsetHours > 14 || offsetMinutes > 59) {
    return null;
  }

  if (offsetHours === 14 && offsetMinutes > 0) {
    return null;
  }

  const offsetSign = match[9] === "-" ? -1 : 1;
  const offsetTotalMinutes = offsetSign * (offsetHours * 60 + offsetMinutes);

  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(
    hour,
    minute,
    second,
    Math.trunc(Number(fraction.padEnd(6, "0").slice(0, 3))),
  );

  const utc = new Date(date.getTime() - offsetTotalMinutes * 60_000);
  const utcYear = utc.getUTCFullYear();

  if (utcYear < 0 || utcYear > 9999) {
    return null;
  }

  return [
    `${pad(utcYear, 4)}-${pad(utc.getUTCMonth() + 1, 2)}-${pad(utc.getUTCDate(), 2)}`,
    `T${pad(utc.getUTCHours(), 2)}:${pad(utc.getUTCMinutes(), 2)}:${pad(utc.getUTCSeconds(), 2)}`,
    `.${fraction.padEnd(6, "0")}Z`,
  ].join("");
};

export const UtcInstantSchema = z
  .string()
  .superRefine((value, ctx) => {
    if (normalizeUtcInstant(value) === null) {
      ctx.addIssue({
        code: "custom",
        message:
          "Must be a valid ISO-8601 timestamp with Z or a numeric offset",
      });
    }
  })
  .transform((value) => normalizeUtcInstant(value) as string);

export type UtcInstant = z.infer<typeof UtcInstantSchema>;

export const isUtcInstant = (value: string): boolean =>
  normalizeUtcInstant(value) !== null;

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
