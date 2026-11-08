# Database Architecture

## 1. Purpose

Define the architecture and governance principles for the shared PostgreSQL database hosted through Supabase. This document records approved architectural decisions; it is not a finalized SQL schema.

## 2. Database platform and environments

- PostgreSQL is the primary relational database.
- Supabase provides managed database services and integrations.
- Maintain separate Supabase projects for development, staging, and production.
- All shared schema changes are version-controlled in this repository as ordered SQL migrations.
- POS, ordering, and waitlist use shared domain records through approved access paths; do not duplicate business tables per application.
- Keep credentials outside version control and provide safe placeholders in `.env.example`.

## 3. PostgreSQL schema organization

- Use `public` for business tables that are accessed through approved Supabase APIs and protected by RLS.
- Use a non-exposed `private` schema for internal tables, sensitive token hashes, and internal helper functions.
- Keep Supabase-managed schemas under platform control; do not repurpose or modify them without a documented requirement.
- Any additional schema must have a documented purpose, explicit grants, and reviewed RLS implications.
- Exposed schema placement does not replace authorization. All client-accessible business data must have appropriate grants and RLS policies.

## 4. Data modeling principles

- Use UUID primary keys for organizations, branches, profiles, customers, orders, dining sessions, payments, and other business entities. Generate IDs on the database side.
- Use primary keys, foreign keys, unique constraints, and check constraints to enforce relationships and stable business invariants.
- Store monetary values as integer minor units together with an ISO 4217 currency code. Never use floating-point types for money. Currency exponent/scale must be handled consistently for each supported currency; IDR amounts are represented in whole Rupiah.
- Use `timestamptz` for event timestamps and store/compare instants consistently in UTC.
- Store each branch's IANA timezone (for example, `Asia/Jakarta`) for business-local schedules, opening hours, and reporting.
- Use soft deletion for important business entities when recovery or historical references matter. Preserve transactional records such as orders, payments, and audit history.
- Use PostgreSQL enums only for stable, tightly controlled states. Use lookup/configuration tables for values likely to evolve or be managed by Platform Admins, such as subscription plans and entitlements.
- Normalize transactional data where it improves integrity; denormalize only with a documented reason.

## 5. Tenant scoping and relational integrity

- Organization-owned records must include or be traceably related to an organization.
- Branch-scoped records must reference the correct organization and branch. Use composite foreign keys or equivalent database constraints where needed to prevent cross-organization relationships.
- Staff accounts are associated with exactly one organization; branch assignments must reference branches within that organization.
- Customers are platform-wide identities, but access to private customer records remains appropriately scoped and authorized.
- Tenant scope must be enforced in database relationships and authorization policies, not just frontend filters.
- Foreign keys, uniqueness constraints, and RLS policies must be designed together so that invalid cross-tenant relationships cannot be created through alternate access paths.

## 6. Dining-session concurrency and lifecycle

A permanent table QR identifies a table, not a dining session or an authorization credential. On QR resolution, the backend must:
1. Validate the table's organization/branch relationship and operational status.
2. Find the table's active dining session.
3. If no active session exists, create one and ensure concurrent scans cannot create multiple active sessions for the same table.
4. Return the resolved active session context and issue a separate guest token for the requesting device.

The one-active-session-per-table invariant must be enforced at the database level (for example, with a suitable partial unique index over active states) and creation must be transactional. The exact SQL implementation depends on the final status model.

A dining session has one consolidated bill. In the initial release:
- The bill covers all orders placed in the session.
- No split-bill, item-level allocation, customer-level allocation, or partial-payment feature is implemented.
- The initial payment flow records one full-settlement cash payment for the outstanding balance.
- Payment records remain separate entities from dining sessions. The relationship should remain extensible to support multiple payment records in a future release, without implementing that workflow now.
- A session closes only after its entire outstanding balance is successfully settled.

Closing a dining session must be a trusted backend transaction that verifies full settlement, changes the session state, and invalidates/revokes all guest tokens for that session. The same table QR can create a new session after closure. Guests cannot directly create, close, reopen, or select arbitrary sessions.

## 7. Database functions and transactions

Use narrowly scoped database functions/RPCs or trusted server-side operations when an operation needs atomic database-side behavior, controlled access, or a stable shared contract. Candidate transactional operations include:
- Resolve table QR, find-or-create the active dining session, and register a per-device guest token through a trusted flow.
- Validate a guest token and submit an order with its items idempotently.
- Record a full-settlement cash payment and update payment/order/session balances atomically.
- Close a dining session only after full settlement and revoke all associated guest tokens.
- Enforce one active queue entry per customer and branch.
- Enforce subscription entitlements, including branch-creation limits.

Keep token generation and raw-token delivery in a trusted server-side boundary. Store only token hashes. Do not expose service-role credentials or privileged database access to browser clients. Function boundaries and grants must be reviewed; avoid placing unrelated business logic in one large function.

## 8. Guest token persistence

- Store guest token hashes, never raw tokens.
- Keep token records in the non-exposed `private` schema.
- Scope each token to its dining session and device, with expiry and revocation metadata.
- Generate raw tokens and deliver them only through trusted server-side code.
- Revoke all tokens associated with a dining session when that session closes.
- A table QR is a public table locator, not a staff credential or direct authority to access a session.

## 9. Transactional history, corrections, and audit logging

- Treat completed orders and settled payments as historical records.
- Do not silently overwrite financial history. Represent corrections through explicit adjustment, void, or other audited records/operations appropriate to the finalized payment workflow.
- Preserve transactional records and audit history when related operational entities are soft-deleted.
- Maintain centralized audit records for sensitive actions, including role changes, branch changes, subscription changes, organization suspension, payment events, and administrative interventions.
- Audit records should capture the actor, organization context, action, timestamp, and relevant change metadata. Access to audit records must itself be restricted.

## 10. Indexing strategy

- Add indexes based on known query patterns, joins, foreign-key access, and authorization lookups.
- Evaluate indexes for organization and branch scoping, foreign keys, status/date filters, and unique business constraints.
- Use unique and partial unique indexes where they enforce approved invariants, such as one active dining session per table or one active waitlist entry per customer and branch.
- Avoid speculative indexes without a query or integrity use case; validate important indexes with realistic query plans and data volumes.

## 11. Migrations

- All schema changes are SQL migrations stored in the repository's established migration directory.
- Use the migration naming convention supported by the installed Supabase CLI/tooling.
- Migrations must be ordered, reviewable, and reproducible.
- Do not edit migrations already applied to shared environments; create a new migration.
- Avoid destructive changes without an approved data migration and recovery plan.
- Test migrations against a development database before promoting them to staging and production.
- Keep seed data separate from production migrations unless tooling and purpose explicitly require otherwise.

## 12. Storage

Use Supabase Storage only for files that need persistent storage. Define bucket purpose, visibility, allowed file types and size, object paths, upload/read authorization, and deletion/retention behavior. Do not store secrets or sensitive payment credentials in Storage.

## 13. Testing and operations

Test:
- Migration application on a clean database and upgrades from the prior supported version.
- Constraints, foreign keys, and cross-tenant relationship prevention.
- RLS policies and tenant isolation.
- Transactional functions, idempotency, and rollback behavior.
- Concurrent first scans of the same table.
- Simultaneous guest order submissions.
- Full-settlement payment idempotency and session closure/token invalidation.
- One-full-payment initial-release behavior and rejection of partial/split-payment attempts.
- Critical indexes and realistic query plans.
- Repeatable seed data.
- Backup, restore, and production migration procedures before production.

## 14. Approved decisions and remaining implementation details

The following architecture decisions are approved:
- `public` and non-exposed `private` schema responsibilities as described above.
- UUID primary keys generated by the database.
- Organization and branch relational integrity enforced with database constraints and authorization policies.
- Integer minor-unit money representation with ISO currency codes; no floating-point money.
- UTC `timestamptz` event timestamps and branch IANA timezones.
- Deliberate soft deletion and preservation of transactional history.
- PostgreSQL enums for stable states and lookup/configuration tables for evolving values.
- Centralized audit logging for sensitive operations.
- Query- and integrity-driven indexing.
- Narrowly scoped transactional database functions or trusted server-side operations.
- Hashed, private, session-scoped guest token persistence.
- Audited corrections rather than silent changes to financial history.
- Ordered, immutable-applied SQL migrations and separate environment projects.

The following details remain for later design and implementation review; their existence does not reopen the approved principles above:
- Exact table names, columns, constraints, indexes, and enum values.
- Exact function/RPC boundaries, grants, and idempotency keys.
- Guest token expiry, rotation, and cleanup schedule.
- Detailed payment correction, void, refund, and reconciliation workflows.
- Archival and retention schedules, including legal and backup requirements.
- Exact concurrency implementation and operational retry behavior.

Do not create or apply production SQL migrations until the detailed data model and dependent contracts have been reviewed and approved.
