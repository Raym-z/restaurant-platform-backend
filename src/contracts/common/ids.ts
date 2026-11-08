import { z } from "zod";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const UuidSchema = z.string().regex(UUID_PATTERN, "Must be a UUID");

export type Uuid = z.infer<typeof UuidSchema>;

/**
 * Opaque idempotency key. The backend stores the key with an operation and
 * actor scope; clients must not reuse a key for a different request.
 */
export const IdempotencyKeySchema = z
  .string()
  .min(16)
  .max(128)
  .regex(
    /^[A-Za-z0-9_-]+$/,
    "Must contain only letters, numbers, underscore, or hyphen",
  );

export type IdempotencyKey = z.infer<typeof IdempotencyKeySchema>;

export const SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

export const SlugSchema = z
  .string()
  .min(1)
  .max(80)
  .regex(SLUG_PATTERN, "Must be a lowercase slug");

export type Slug = z.infer<typeof SlugSchema>;

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export const EmailSchema = z
  .string()
  .max(320)
  .regex(EMAIL_PATTERN, "Must be a valid email address");

export type Email = z.infer<typeof EmailSchema>;

export const PHONE_E164_PATTERN = /^\+[1-9]\d{1,14}$/;

export const PhoneE164Schema = z
  .string()
  .regex(PHONE_E164_PATTERN, "Must be an E.164 phone number");

export type PhoneE164 = z.infer<typeof PhoneE164Schema>;
