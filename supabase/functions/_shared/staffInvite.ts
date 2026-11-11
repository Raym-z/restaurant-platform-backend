/**
 * Pure helpers for the staff invitation Edge Function.
 *
 * Keeping these free of Deno and Supabase clients lets the static test suite
 * exercise email normalization, redirect construction, and the "existing Auth
 * account" classification without a running Edge runtime.
 */

export type AuthAdminErrorLike = {
  message?: string;
  status?: number;
  code?: string;
};

const EXISTING_AUTH_USER_PATTERNS = [
  "already been registered",
  "already registered",
  "user already exists",
  "email address has already",
  "email exists",
];

/**
 * Normalize an invitation email exactly as the database expects. The database
 * repeats this validation; the Edge Function must not be the only gate.
 */
export const normalizeInvitationEmail = (value: string): string =>
  value.trim().toLowerCase();

/**
 * Supabase Auth returns a controlled error when `inviteUserByEmail` targets an
 * existing account. Detect that case so the function can send a magic link
 * instead. Never surface this distinction to the caller.
 */
export const isExistingAuthUserError = (error: AuthAdminErrorLike): boolean => {
  const message = (error.message ?? "").toLowerCase();
  return EXISTING_AUTH_USER_PATTERNS.some((pattern) =>
    message.includes(pattern),
  );
};

/**
 * Build the POS acceptance URL. The raw token is carried in the `invitation`
 * query parameter of the redirect target and is never stored by the POS.
 */
export const buildAcceptanceRedirect = (
  acceptanceUrl: string,
  rawToken: string,
): string => {
  const url = new URL(acceptanceUrl);
  url.searchParams.set("invitation", rawToken);
  return url.toString();
};

/**
 * Safe, non-enumerating delivery failure payload. The same payload is returned
 * whether or not an Auth account already exists.
 */
export const INVITATION_DELIVERY_FAILURE_MESSAGE =
  "The invitation could not be delivered. No account access was granted.";
