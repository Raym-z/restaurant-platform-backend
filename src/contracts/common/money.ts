import { z } from "zod";

/**
 * ISO 4217 alphabetic currency code. The database remains authoritative for
 * supported currencies and their exponents.
 */
export const CurrencyCodeSchema = z
  .string()
  .regex(/^[A-Z]{3}$/, "Must be a three-letter ISO 4217 currency code");

export type CurrencyCode = z.infer<typeof CurrencyCodeSchema>;

/**
 * Integer minor units. Floating-point monetary values are never accepted.
 */
export const MinorUnitsSchema = z
  .number()
  .int()
  .min(Number.MIN_SAFE_INTEGER)
  .max(Number.MAX_SAFE_INTEGER);

export type MinorUnits = z.infer<typeof MinorUnitsSchema>;

export const NonNegativeMinorUnitsSchema = MinorUnitsSchema.min(0);

export const MoneySchema = z
  .object({
    amountMinor: MinorUnitsSchema,
    currency: CurrencyCodeSchema,
  })
  .strict();

export type Money = z.infer<typeof MoneySchema>;

export const NonNegativeMoneySchema = z
  .object({
    amountMinor: NonNegativeMinorUnitsSchema,
    currency: CurrencyCodeSchema,
  })
  .strict();

export type NonNegativeMoney = z.infer<typeof NonNegativeMoneySchema>;

export const isSameCurrency = (
  left: Pick<Money, "currency">,
  right: Pick<Money, "currency">,
): boolean => left.currency === right.currency;

/**
 * Billing arithmetic (tax, service charge, discounts, rounding) is intentionally
 * not implemented here. Those rules require explicit business approval.
 */
