# Edge Function tests

Edge Functions are owned by Agent 2. This directory holds the harness-level
tests that validate them through the local HTTP boundary.

Planned coverage (blocked until Agent 2 publishes functions/contracts):

- Guest table resolution, reconnect, and order submission.
- Token validation, expiry/revocation, and cross-session rejection.
- Response envelope, error codes, and HTTP status mapping.
- No service-role key or raw token leakage.
- Rate limiting where implemented.
- Notification provider calls mocked; no real network delivery.

`npm run test:edge` skips cleanly while `supabase/functions/` is absent.
