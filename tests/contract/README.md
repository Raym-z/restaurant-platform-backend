# Contract tests

Agent 2 owns `src/contracts/` and the runtime validation schemas. Agent 3 owns
the runner and cross-cutting checks.

Planned checks (blocked until Agent 2 publishes contracts):

- Zod schema round-trips and rejection of unknown/invalid fields.
- Error catalog consistency between shared TypeScript definitions and database
  error codes.
- Response envelope shape for trusted Edge Function endpoints.
- HTTP status mapping.
- No internal SQL errors, stack traces, service-role keys, or raw guest tokens
  in responses.

Run with `npm run test:static` (no database required).
