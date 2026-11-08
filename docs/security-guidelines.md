# Security Guidelines

## 1. Purpose

Define minimum security requirements for the shared restaurant platform backend and its consuming applications.

## 2. Security principles

- Enforce least privilege.
- Treat all browser input as untrusted.
- Enforce authoritative business rules on the backend.
- Isolate organizations and branch-scoped resources.
- Minimize collection, exposure, and retention of personal data.
- Make sensitive operations auditable.
- Fail closed when authorization or resource state cannot be verified.

## 3. Tenant and branch isolation

- Every organization-owned record must be scoped to its organization.
- Branch-specific records must be scoped to the correct branch and organization.
- Each staff account belongs to exactly one organization; branch access is limited by its assignments and permissions.
- Customer accounts are universal but private customer records remain owner-scoped.
- Never trust client-supplied organization, branch, table, session, role, price, or payment-state values without server-side validation.
- Test cross-organization and cross-branch access explicitly.

## 4. Authentication and authorization

- Keep staff and customer identity domains separate.
- Require staff authentication for POS operations.
- Limit customer access to their own protected records.
- Guest ordering does not create Supabase Auth users; it uses custom per-device guest session tokens.
- Limit guest tokens to public ordering operations for one active dining session.
- Enforce role, permission, organization, and branch scope on the backend.
- Revalidate authorization and resource state for sensitive state changes.

## 5. Guest token and QR security

- Treat permanent table QR identifiers as public locators, not secrets or authorization credentials.
- Generate guest tokens using a cryptographically secure random generator with sufficient entropy.
- Issue a distinct token per guest device, even when multiple devices join the same dining session.
- Store token hashes rather than raw tokens; return raw tokens only to the issuing device over TLS.
- Scope each token to one dining session and explicitly permitted operations.
- Validate token status and active session state on every state-changing request.
- Revoke individual tokens when needed and invalidate all session tokens when the dining session closes.
- Reject closed, expired, revoked, malformed, or unknown tokens.
- Apply rate limiting, abuse detection, and safe error responses to public endpoints.
- Never log raw guest tokens or include them in Realtime payloads.
- Never use a guest token to authorize staff operations, payments, or session lifecycle control.

## 6. Database and RLS

- Enable RLS on applicable exposed tables.
- Maintain policies through migrations.
- Test SELECT, INSERT, UPDATE, and DELETE independently where applicable.
- Use constraints to enforce relationship integrity and one active dining session per table.
- Review security-definer functions carefully, including explicit `search_path`, grants, and caller validation.
- Prefer narrowly scoped trusted functions for guest token validation and order submission; do not grant broad anonymous table access.
- Never expose service-role credentials to browser code.

## 7. Input and application security

- Validate request schemas on the server.
- Recalculate and validate authoritative order prices and totals on the backend.
- Enforce business invariants in trusted backend logic.
- Use safe query patterns.
- Prevent mass assignment of protected fields.
- Protect against injection, XSS, CSRF where applicable, broken access control, replay, and duplicate requests.
- Use idempotency for retryable order and payment operations.
- Return safe errors without stack traces or secrets.

## 8. Secrets and configuration

- Keep service-role keys and privileged credentials server-side only.
- Do not commit real `.env` files or credentials.
- Provide safe placeholders in `.env.example`.
- Separate development, staging, and production configuration.
- Rotate exposed credentials promptly.
- Restrict access to production secrets.

## 9. Customer data and location

Collect only data required for a feature. Restrict customer profile and queue information to authorized access.

For optional waitlist location verification:
- Request location only when needed.
- Perform distance checks server-side using branch coordinates and configured radius.
- Treat browser GPS as a presence signal, not proof of identity; browser location can be spoofed.
- Avoid retaining precise coordinates unless explicitly justified and approved; prefer transient distance evaluation.

## 10. Payment and dining-session settlement security

The initial release supports cash-only POS order payments:
- Validate the current outstanding order/session balance and amount received.
- Calculate or verify change on the trusted side.
- Record the staff actor and relevant transaction details.
- Prevent duplicate submissions through idempotency and transaction controls.
- Restrict corrections and cancellations and maintain audit history.
- Recalculate the entire dining-session outstanding balance on the backend.
- Close a dining session only after its entire outstanding balance is successfully settled.
- Invalidate all guest tokens as part of session closure so no further guest orders can be accepted.

The initial release uses one consolidated bill and one full-settlement cash payment per dining session. Do not implement split bills, partial payments, or payment allocation by customer/item. Keep payment records separate from dining sessions and preserve future extensibility. Do not collect or store card numbers, CVVs, gateway tokens, or e-wallet credentials. Do not implement payment gateway or online order-payment integrations in the initial release.

## 11. Realtime and Storage

Realtime subscriptions and Storage object access require their own authorization review. Do not assume that a table's RLS policy automatically secures every channel or Storage object. Guest clients must receive only minimal information scoped to their active session. Test each access path independently.

## 12. Logging and auditing

Log security-relevant actions where appropriate, including membership/role/branch assignment changes, sensitive order changes, cash payment corrections, dining-session creation/closure, guest-token revocation, and queue overrides.

Never log passwords, raw Auth tokens, raw guest tokens, or unnecessary personal information. Protect audit records against unauthorized modification.

## 13. Security testing

Include tests for unauthenticated access, cross-organization and cross-branch access, role and permission enforcement, RLS behavior, customer record ownership, valid/invalid/expired/revoked guest tokens, token use against another session, closed-session order rejection, simultaneous first QR scans, duplicate order/payment submissions, unauthorized payment changes, full-balance settlement, token invalidation on closure, Realtime/Storage isolation, input validation, and rate limiting.

## 14. Incident readiness

Before production, document credential rotation, incident triage, backup/restore, data exposure response, and relevant notification responsibilities.
