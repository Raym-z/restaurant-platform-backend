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

M2.1 adds `20261108120000_m2_branch_scoped_staff_roles.sql`, which introduces `staff_role_assignments.branch_id`, the per-scope uniqueness rules, the branch/role consistency trigger, and the deterministic legacy backfill described in §5. The follow-up `20261109120000_m2_branch_scoped_staff_roles_fixes.sql` makes the consistency trigger conflict-safe, serializes concurrent revocations, and adds the branch/organization FK index. `20261109130000_m2_staff_rpc_concurrency_and_errors.sql` fixes the revocation lock order and serializes branch-assignment revocation; `20261109140000_m2_staff_admin_error_normalization.sql` normalizes the remaining staff-administration missing/cross-tenant errors.

M3 adds `20261108110700_m3_order_schema_extensions.sql`,
`20261108110800_m3_order_state_guards.sql`,
`20261108110900_m3_pos_read_helpers.sql`,
`20261108111000_m3_table_session_rpcs.sql`, and
`20261108111100_m3_order_rpcs.sql` after the security-remediation migrations.
The combined branch renumbers M3's terminal-state guard from
`20261109140000` to `20261109140100_m3_order_insert_terminal_state_guard.sql`
to avoid colliding with M2's error-normalization migration; the SQL is
unchanged. See `docs/m3-core-pos-operations.md` for the combined ordering
evidence.

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

`public.staff_role_assignments.branch_id` makes the scope concrete:

- Organization-scoped assignments have `branch_id IS NULL`.
- Branch-scoped assignments have a non-null `branch_id`.
- `(branch_id, organization_id)` references `public.branches (id, organization_id)`, so a branch assignment can never point at another tenant's branch.
- A check constraint enforces the null/non-null rule, and a trigger rejects invalid role/scope combinations.

Active uniqueness is split by scope:

- `staff_role_assignments_active_organization_role_unique`: one active organization-scoped assignment per `(staff_id, role_code)`.
- `staff_role_assignments_active_branch_role_unique`: one active branch-scoped assignment per `(staff_id, role_code, branch_id)`.
- `staff_role_assignments_one_active_owner`: unchanged one-active-Owner-per-organization invariant.

A staff member may therefore be Manager at Branch A and Cashier at Branch B, but cannot hold two active Manager assignments at Branch A. Revoked rows do not participate in the active uniqueness indexes and can be replaced.

### Effective permission rules for Agent 2

1. Branch assignments grant no permission by themselves.
2. A branch-scoped role grants permissions only at its specific `branch_id`, and only while the matching branch assignment is active. An `AFTER INSERT OR UPDATE` trigger creates the matching active branch assignment when a branch-scoped role is recorded, so the two records stay consistent without a required second call.
3. An organization-scoped role grants permissions across all branches; branch assignments do not reduce that reach. When `authz.has_permission` is called with a non-null branch for an organization-scoped role, that branch must be active and in the staff member's organization; `null` means the caller is checking an organization-wide permission without branch context.
4. Owner is organization-wide and requires no branch assignment.
5. Multiple roles combine as a union of permissions.
6. Revoked assignments and inactive staff are ignored.
7. Branch-scoped staff see only branches where they hold a branch-scoped role and an active branch assignment; organization-scoped staff see all branches.

### Legacy branch-role backfill

Migration `20261108120000_m2_branch_scoped_staff_roles.sql` backfills legacy branch-scoped rows (which had no `branch_id`) deterministically. The migration takes `LOCK TABLE public.staff_branch_assignments IN SHARE MODE` immediately before invoking the backfill, so concurrent branch-assignment writes cannot interleave with the split. Follow-up migrations `20261109120000_m2_branch_scoped_staff_roles_fixes.sql`, `20261109130000_m2_staff_rpc_concurrency_and_errors.sql`, and `20261109140000_m2_staff_admin_error_normalization.sql` make the branch-assignment consistency trigger conflict-safe, serialize concurrent revocations, fix revocation lock order, normalize staff-administration errors, and retain the function-level backfill lock for later manual invocations.

1. For each legacy active assignment, its target branches are the staff member's active `staff_branch_assignments`.
2. The original row receives the first branch and additional rows are inserted for the remaining branches, preserving the assigned actor, reason, `assigned_at`, `created_at`, and revocation state. The original row's `updated_at` is refreshed by the table's `updated_at` trigger; duplicate rows copy the pre-migration `updated_at`.
3. This preserves the exact effective branch reach of the old model. It never adds a branch.
4. A legacy row with no usable branch assignment cannot be represented without inventing access. The migration raises `LEGACY_BRANCH_ROLE_UNASSIGNED` and rolls back.

#### Pre-flight classification

Before applying the migration to a database that may contain legacy branch-scoped assignments, run:

```sql
with assignment_stats as (
  select sra.id,
         sra.staff_id,
         sra.role_code,
         sra.revoked_at as role_revoked_at,
         sp.status as staff_status,
         count(sba.id) filter (where sba.revoked_at is null) as active_branch_assignments,
         count(sba.id) as historical_branch_assignments
    from public.staff_role_assignments sra
    join public.staff_profiles sp on sp.id = sra.staff_id
    left join public.staff_branch_assignments sba
      on sba.staff_id = sra.staff_id
     and sba.organization_id = sra.organization_id
   where sra.scope_type = 'branch'
   group by sra.id, sra.staff_id, sra.role_code, sra.revoked_at, sp.status
)
select *,
       case
         when role_revoked_at is not null and historical_branch_assignments = 0
           then 'revoked_no_history'
         when role_revoked_at is not null
           then 'revoked_with_history_auto_split'
         when active_branch_assignments = 0 and staff_status <> 'active'
           then 'inactive_staff_no_active_assignment'
         when active_branch_assignments = 0
           then 'active_role_no_active_assignment'
         else 'active_auto_split'
       end as reconciliation_action
  from assignment_stats
 order by reconciliation_action, staff_id, role_code;
```

`reconciliation_action` means:

- `active_auto_split`: active role with at least one active branch assignment. No manual action; the migration splits it.
- `revoked_with_history_auto_split`: revoked role with historical branch assignments. No manual action; the migration splits it for audit history.
- `active_role_no_active_assignment`: active role with no active assignment. Create the intended `staff_branch_assignments` row or revoke the legacy role. Do not invent a branch merely to make the row fit.
- `inactive_staff_no_active_assignment`: active role for a staff member who is not currently active, with no active assignment. Decide whether the staff member will be reactivated. If they will return, create the intended assignment; if not, revoke the legacy role.
- `revoked_no_history`: revoked role with no historical assignment. The row is inert but cannot be represented under the new `branch_id NOT NULL` rule for branch scope. Back up the row, then remove it from the live table with explicit approval. Do not fabricate a branch. If retention policy requires keeping it, the migration remains blocked until a reviewed decision is made.

#### Reconciliation procedure

1. Take a backup of `public.staff_role_assignments` and `public.staff_branch_assignments` (see below).
2. Run the pre-flight query and export its output for review.
3. Reconcile every non-auto row:
   - For `active_role_no_active_assignment` and `inactive_staff_no_active_assignment`, create the verified intended assignment or revoke the role.
   - For `revoked_no_history`, export the row and, with explicit approval, delete the inert row.
4. Re-run the pre-flight query until only `active_auto_split` and `revoked_with_history_auto_split` remain.
5. Apply the migration inside a single transaction. The Supabase CLI/pgx path is transactional; if using `psql`, use `-1` (single transaction) and `ON_ERROR_STOP=1`.
6. Validate after apply: no branch-scoped row has `branch_id IS NULL`; the new partial unique indexes exist; the one-active-Owner index still exists; and the authorization/RLS tests pass.

#### Active legacy role with a revoked assignment

An active legacy role is mapped only across **active** `staff_branch_assignments`. If every assignment for that role has been revoked, the backfill raises `LEGACY_BRANCH_ROLE_UNASSIGNED`, even though the role itself is active. Treat it like an unassigned active role: restore the intended active assignment or revoke the role before applying the migration. Do not invent a branch.

After the role is mapped, the normal lifecycle applies: revoking the branch assignment suspends access while the role remains active, and re-assigning the branch restores the role. The SQL regression suite covers this restore/suspend/restore sequence.

#### Locking, maintenance, backup, and recovery

- **Locking:** `ALTER TABLE ... ADD COLUMN` takes `ACCESS EXCLUSIVE` on `public.staff_role_assignments` for the whole migration transaction. Reads and writes to that table block until commit. The backfill is row-by-row and the new indexes are built non-concurrently. The migration takes `LOCK TABLE public.staff_branch_assignments IN SHARE MODE` immediately before invoking the backfill, so branch-assignment writes (including `assign_staff_branch`, `revoke_staff_branch`, and the role-consistency trigger) wait until the migration transaction completes. The helper retains the same lock for later manual invocations. Plan a maintenance/low-traffic window and avoid concurrent staff-role changes during the run.
- **Minimum migration range:** Apply every migration through `20261109140000_m2_staff_admin_error_normalization.sql`, which includes `20261109130000_m2_staff_rpc_concurrency_and_errors.sql`. Do **not** stop at `20261109120000_m2_branch_scoped_staff_roles_fixes.sql`: that leaves the earlier `revoke_staff_role` lock order in place (role row lock before the organization advisory lock) and retains the grant-vs-revoke deadlock risk. The final F2 lock-order correction is in `20261109130000`; `20261109140000` adds the staff-administration error normalization.
- **Backup:** before applying, keep a restorable copy, for example:
  ```sql
  create schema if not exists migration_backup;
  create table migration_backup.staff_role_assignments_m21 as
    select * from public.staff_role_assignments;
  create table migration_backup.staff_branch_assignments_m21 as
    select * from public.staff_branch_assignments;
  ```
  Use a timestamped backup name in production and restrict access to the backup schema. A `pg_dump` of the two tables is equally valid.
- **Transactional failure:** if the migration aborts inside a transaction, the new column, constraints, indexes, backfill, and function changes roll back together. Fix the pre-flight issue and re-run; do not re-run blindly.
- **Non-transactional runners:** if a runner splits statements, a failure can leave the new `branch_id` column, the dropped old index, or partially backfilled data. Stop, restore the backup, inspect the catalog, and retry only after cleanup. Never rely on manual production edits.
- **Rollback after success:** there is no automatic down migration. The backfill is a one-way split of one legacy row into one row per branch. Reverting requires either restoring the backup or explicitly merging per-branch rows (keeping one row per staff/role and discarding the branch distinction). The merge loses per-branch history and can fail against the old `(staff_id, role_code, scope_type)` uniqueness rule unless rows are merged first. Test recovery on a disposable database before production.

### Owner invariant

- The database enforces **at most one active Owner per organization** via a partial unique index on active `owner` assignments.
- The database also prevents removal or deactivation of the last active Owner. `staff_role_assignments_guard_last_owner` blocks revoking, replacing, or deleting the last active Owner assignment, and `staff_profiles_guard_last_owner` blocks deactivating the last active Owner's staff profile. Both raise `LAST_OWNER_PROTECTED`. Application workflows must surface that error and must not bypass the triggers; ownership transfer remains unavailable in the initial release.

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
