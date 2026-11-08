# Database Foundation Implementation

This document describes the schema implemented by the database-foundation workstream. It is an implementation companion to the approved architecture documents under `docs/`. It does not redefine approved business rules.

## 1. Ownership boundary

Implemented here:

- `public` and `private` schema organization.
- Tables, columns, enums, primary keys, foreign keys, checks, unique/partial indexes.
- Tenant-consistent composite foreign keys.
- Soft-delete fields and historical-record protections.
- Audit table and append-only protections.
- Scoped idempotency storage.
- Reference seed data.
- Ordered Supabase migrations.

Not implemented here:

- RLS policies.
- Grants to `anon` or `authenticated`.
- Authorization helper functions.
- RPCs and Edge Functions.
- Application contracts or TypeScript types.
- Test harness, CI, and fixtures.

Those remain owned by Agent 2 (RLS policies and backend services) and Agent 3 (testing infrastructure).

## 2. Schema exposure and privileges

### Schemas

- `public`: exposed Supabase business schema. Every table has RLS enabled.
- `private`: non-exposed internal schema for guest token hashes, idempotency records, and internal trigger functions.
- `auth`: Supabase-managed; referenced by staff/customer/platform-admin profile foreign keys. Not modified.

`private` usage is revoked from `PUBLIC`, `anon`, and `authenticated`. `service_role` receives usage and table privileges where the migration role can grant them.

### Default privileges

The bootstrap migration protects future objects created by the migration role:

- `public`: revoke all table, sequence, and function privileges from `PUBLIC`, `anon`, and `authenticated`.
- `private`: revoke all table, sequence, and function privileges from `PUBLIC`, `anon`, and `authenticated`.
- `private`: grant table, sequence, and function privileges to `service_role` when that role exists.

PostgreSQL default privileges are role-specific. Every table migration also explicitly enables RLS and revokes privileges from `anon`/`authenticated`. Future tables must do the same; default privileges do not cover objects created by a different role.

Function execution is revoked from `PUBLIC` on every internal trigger function. Agent 2 must explicitly grant execute on any RPC/helper intended for client use.

### RLS status

RLS is enabled on all `public` tables, including reference/lookup tables. No policies exist yet. This is intentional deny-by-default behavior. Agent 2 must add reviewed policies and grants before application access.

`private` tables also have RLS enabled with no policies. Client roles have no schema usage anyway; `service_role` bypasses RLS.

## 3. Migration order

| File | Purpose |
|---|---|
| `20261108090000_bootstrap.sql` | `private` schema, default privileges, enums, shared trigger functions, comments |
| `20261108090100_reference_data.sql` | currencies, plans, plan entitlements, five roles, permissions, role permissions |
| `20261108090200_tenancy_and_subscriptions.sql` | organizations, branches, subscriptions, subscription events |
| `20261108090300_identity_and_access.sql` | staff profiles, role/branch assignments, customer profiles, platform admins, exceptional access |
| `20261108090400_menu_and_charges.sql` | menu categories/items, branch availability, modifiers, charge configuration |
| `20261108090500_tables_sessions_and_tokens.sql` | restaurant tables, QR identifiers, dining sessions, private guest tokens |
| `20261108090600_orders.sql` | session discounts, orders, order items, modifier snapshots |
| `20261108090700_billing_and_payments.sql` | bills, current-bill FK, bill orders/discounts, payments |
| `20261108090800_waitlist.sql` | waitlist entries |
| `20261108090900_audit_and_idempotency.sql` | audit events, scoped idempotency keys |
| `20261108091000_integrity_guards_and_indexes.sql` | snapshot immutability triggers and cross-cutting comments |

Agent 2 migrations should use later timestamps and merge after the schema. Do not edit applied migrations.

## 4. Tenant consistency

Branch-scoped tables store both `organization_id` and `branch_id` and use composite foreign keys:

```sql
foreign key (branch_id, organization_id)
references public.branches (id, organization_id)
```

Additional composite keys enforce:

- `orders.current_bill_id` shares the order's organization, branch, and dining session.
- `bills.replacement_bill_id` shares the original bill's organization, branch, and dining session.
- `bill_orders` links bills and orders from the same organization, branch, and session.
- Menu availability, staff assignments, waitlist entries, and charge overrides cannot cross tenants.

## 5. Roles, scope, and the Owner invariant

Exactly five roles are seeded:

- `owner`
- `admin`
- `manager`
- `cashier`
- `kitchen_staff`

Host/Queue Staff is out of initial scope.

Allowed scope by role:

| Role | Scope |
|---|---|
| Owner | organization only |
| Admin | organization or branch |
| Manager | branch only |
| Cashier | branch only |
| Kitchen Staff | branch only |

A database trigger rejects invalid role/scope combinations.

### Effective permission rules for Agent 2

1. Branch assignments grant no permission by themselves.
2. A branch-scoped role grants permissions only for actively assigned branches.
3. An organization-scoped role grants permissions across all branches; branch assignments do not reduce that reach.
4. Owner is organization-wide and requires no branch assignment.
5. Multiple roles combine as a union of permissions.
6. Revoked assignments and inactive staff are ignored.
7. Branch-scoped staff see only assigned branches; organization-scoped staff see all branches.

### Owner invariant

- The database enforces **at most one active Owner per organization** via a partial unique index on active `owner` assignments.
- The database does **not** enforce that an organization always retains at least one Owner. Agent 2 must prevent loss of the last active Owner through role revocation, staff deactivation, account deletion, or ownership transfer.

## 6. Menu availability

The schema does not assume menu items are automatically available at every branch.

It provides:

- `branch_menu_categories`: branch/category availability.
- `branch_menu_items`: branch/item availability and nullable price override.

Supported contracts:

1. **Explicit opt-in:** rows are required for an item/category to be sellable at a branch. Safest against unintended exposure; more setup work.
2. **Default available, opt-out:** absent rows mean available at organization base price. Less administration; new items appear automatically.
3. **Organization-level default plus branch overrides:** requires additional approved default configuration.
4. **Separate branch catalogs:** not recommended; heavy duplication.

The approved option and category/item precedence must be defined by Agent 2 before implementing menu queries. No migration encodes an availability default.

## 7. Guest tokens and historical orders

- `private.guest_tokens` stores only token hashes, expiry, revocation, and session scope.
- Tokens may be deleted after retention.
- `orders` has **no guest-token foreign key**.
- Guest orders are identified by `source = 'guest'` and `dining_session_id`.
- Token validity is enforced only during order submission by Agent 2/Edge Functions.
- Orders remain valid after token cleanup because dining sessions are never deleted.

## 8. Idempotency

`private.idempotency_keys` uses scoped uniqueness:

```text
(scope_type, scope_id, operation, idempotency_key)
```

Supported scopes:

- `auth_user`
- `organization`
- `staff`
- `customer`
- `guest_session`
- `platform_admin`

Agent 2 must derive `scope_id` from trusted context, choose the scope per operation, compare request fingerprints, and define retention. Guest order retries should use `guest_session`, not a token ID.

## 9. Billing and payments

- A bill row is created at explicit finalization.
- Finalized financial fields are frozen by trigger.
- `bills.status` supports `finalized`, `settled`, and `voided`.
- Reopening is proposed as void-and-replace: the original bill is voided and linked to a replacement; it is never edited.
- No reopen workflow, state-transition trigger, or payment-void workflow is implemented here. Agent 2 owns those workflows.
- `orders.current_bill_id` and `bills.replacement_bill_id` are tenant/session-consistent composite FKs.
- One completed payment per bill is enforced by a partial unique index.
- A completed payment must:
  - use cash;
  - reference a finalized, non-voided bill;
  - match the bill currency and grand total;
  - cover the amount due;
  - calculate change as received minus due.
- There is no partial payment status. Partial payments are not representable as successful payments.
- Payment void/correction/refund lifecycle is deferred to Agent 2.

## 10. Order-item arithmetic

Initial proposed calculation:

```text
effective_unit_price = base_unit_price + modifier_unit_delta
line_total           = effective_unit_price * item_quantity
```

- `base_unit_price_minor` snapshots the effective branch price.
- `modifier_unit_delta_minor` is the per-unit sum of selected option deltas.
- `effective_unit_price_minor` and `line_total_minor` are generated columns.
- Negative modifier deltas are permitted by the schema but must keep the effective unit price nonnegative. The final sign policy remains unresolved.
- No independent modifier quantity is implemented initially.
- M3 order RPCs validate the modifier selection and recalculate order subtotal from non-cancelled item lines while the order is mutable. No deferred trigger validates the aggregate sums; privileged direct writes remain a database-owner concern.
- Order subtotal is recalculated while pending/accepted and immutable once preparation starts.

## 11. Order numbering

The foundation schema has no human display-number column. M3 adds a stable, non-sequential `orders.order_reference` (`ORD-########`) for operational correlation. Per-branch, per-day, and display-code numbering still require a decision and a follow-up migration; consumers must not treat `order_reference` as a per-branch sequence.

## 12. Audit

- `public.audit_events` is append-only.
- INSERT is allowed for trusted backend operations.
- UPDATE, DELETE, and TRUNCATE are blocked by triggers.
- Client roles receive no direct access.
- Agent 2 owns audit write paths, read policies, and retention.

## 13. Seed data

Implemented seeds:

- Currency: `IDR`, minor unit exponent 0.
- Roles: Owner, Admin, Manager, Cashier, Kitchen Staff.

`supabase/seed.sql` is the local Supabase seed entry point. It is idempotent and
contains only the approved reference values above. The same reference values are
inserted by migrations for deployments that do not run the Supabase seed step.
Demo organizations, auth users, plans, permissions, and transactional fixtures
are intentionally not included.

Intentionally not seeded:

- Plans and entitlements (catalog pending).
- Permissions and role-permission mappings (matrix pending).
- Organizations, branches, staff, customers, menus, tables, or transactional data.
- Auth users.

## 14. Deferred decisions and blockers for Agent 2

1. Permission catalog and role-permission matrix.
2. Menu availability option and category/item precedence.
3. Bill reopen/void lifecycle details.
4. Payment void/correction/refund and reconciliation.
5. Idempotency scope per operation and retention.
6. Item-level transition matrix and cancellation billing effects (order-level transitions are implemented by M3).
7. Tax/service/discount calculation order and rounding.
8. Guest token expiry/rotation/cleanup.
9. Order display numbering.
10. Plan catalog, entitlements, and grace duration.
11. Queue reorder algorithm and no-show rules.
12. Customer profile/account lifecycle and auth-user deletion behavior.
13. Audit retention and read policy.
14. Platform-admin exceptional-access scope vocabulary.
15. Staff invitation flow.
16. Public menu access path and RLS policies.
17. Per-branch table label uniqueness.
18. Order subtotal and modifier-sum validation boundaries.

## 15. Verification performed

The migrations were applied in order to a disposable PostgreSQL 18 database with Supabase-like `anon`, `authenticated`, and `service_role` roles plus a mock `auth.users` table. Verification covered:

- Clean migration application.
- Tenant-consistent composite FKs, including `orders.current_bill_id` and `bills.replacement_bill_id`.
- One active dining session per table.
- One active Owner per organization; last-owner preservation intentionally left to Agent 2.
- Valid role/scope enforcement and rejection of invalid combinations.
- Generated order-item line totals.
- Full-settlement payment acceptance, partial/voided-partial rejection, and duplicate completed-payment rejection.
- Payment amount and finalized bill immutability.
- Audit INSERT acceptance and UPDATE/DELETE/TRUNCATE rejection.
- Scoped idempotency collision behavior.
- Guest order survival after guest-token deletion.
- RLS enabled on all public tables and no client table privileges.
- `private` schema isolation and `service_role` access.
- Default privileges on newly created public tables.
- Invalid IANA timezone rejection.
- Absence of per-branch order display numbering and guest-token foreign keys.
