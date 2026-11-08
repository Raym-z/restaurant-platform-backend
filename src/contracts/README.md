# Shared Backend Contracts

This directory contains the canonical TypeScript contracts and Zod runtime
schemas shared by the backend, POS, ordering, and waitlist applications.

## Conventions

- Every wire operation exports a request schema, a response schema, and inferred
  TypeScript types.
- Runtime validation is mandatory at trusted boundaries. TypeScript types do not
  validate incoming requests.
- IDs are UUID strings. Timestamps are ISO-8601 UTC strings ending in `Z`.
- Money is represented as integer minor units plus an ISO 4217 currency code.
  Floating-point monetary values are rejected.
- API responses use the success/error envelopes in `common/api-response.ts`.
- Error codes are a closed union in `common/errors.ts`.
- Roles are limited to Owner, Admin, Manager, Cashier, and Kitchen Staff.
- Role assignments carry an explicit `organization` or `branch` scope. An Admin
  is never assumed organization-wide.
- Permission keys are intentionally treated as opaque strings here. The
  approved role-to-permission mapping is maintained separately and is not
  seeded by this package.
- Guest tokens are raw opaque credentials returned once by a trusted Edge
  Function. Only their SHA-256 hashes are persisted server-side.

## Deliberately out of scope

- Billing arithmetic: tax, service charge, discounts, and rounding require
  explicit business approval before implementation.
- Unapproved order transitions.
- Payment void, correction, and reopening workflows.
- RLS policies, grants, and schema-dependent RPCs. These wait for Agent 1's
  merged schema baseline.

## Checks

```bash
npx tsc --noEmit
npx vitest run src/contracts/common/contracts.test.ts
```
