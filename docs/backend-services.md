# Backend Services Implementation

This document describes the backend-services workstream implementation: RLS,
grants, authorization helpers, RPCs, Edge Functions, and related contracts. It
does not redefine approved business rules. Unapproved decisions remain blocked
and are listed in §9.

## 1. Ownership and migration order

Agent 1 owns the schema foundation. Agent 2 owns RLS, grants, authorization
helpers, RPCs, backend service migrations, Edge Functions, and shared contracts.

Service migrations follow the Agent 1 baseline and are additive:

| Migration                                          | Purpose                                                                                                                                 |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `20261108100000_authz_helpers.sql`                 | `authz` helper schema, staff/customer/platform-admin resolution, role/scope checks, subscription gates, audit writer, last-Owner guards |
| `20261108100100_rls_policies.sql`                  | SELECT policies, approved customer self-profile update, client grants                                                                   |
| `20261108100200_idempotency_helpers.sql`           | Scoped idempotency begin/complete/fail helpers                                                                                          |
| `20261108100300_rpc_organization_branch_staff.sql` | Organization, branch, and staff RPCs                                                                                                    |
| `20261108100400_rpc_menu_tables_sessions.sql`      | Menu, table, QR, dining-session, and guest-token RPCs                                                                                   |
| `20261108100500_rpc_waitlist_platform.sql`         | Waitlist and platform-admin metadata RPCs                                                                                               |

Agent 1 migrations are never edited.

## 2. Authorization helpers

RLS policies need callable helpers. The `private` schema is not usable from
policies because client roles have no schema usage, so helpers used by policies
live in the non-exposed `authz` schema. `authz` is not in the Data API schema
list; authenticated clients receive execute grants only for read-only helpers.

Key helpers:

- `authz.current_staff_id()`, `current_organization_id()`, `current_customer_id()`.
- `authz.is_platform_admin()`.
- `authz.has_org_role(text[])`, `authz.is_org_admin()`.
- `authz.has_branch_access(uuid)`.
- `authz.has_branch_role(uuid, text[])`.
- `authz.can_view_staff(uuid)`.
- `authz.has_permission(text, uuid)` — fail-closed while `role_permissions` is
  empty; no unapproved mappings are seeded.
- `authz.org_subscription_state(uuid)`, `authz.org_is_restricted(uuid)`.
- `authz.has_exceptional_access(uuid, text)` — exists, but no platform access
  policy uses it until the scope vocabulary is approved.
- `authz.require_staff_id()`, `assert_org_role`, `assert_branch_access`,
  `assert_branch_role`, `assert_org_operational`, `assert_org_can_administer`.

Scope enforcement follows documented role scope:

- Owner is organization-wide.
- Admin is organization-wide only when the assignment is organization-scoped.
- Manager, Cashier, and Kitchen Staff are branch-scoped.
- Branch assignments grant no permission by themselves; a branch-scoped role
  assignment and an active branch assignment are both required.

## 3. Last-Owner protection

The schema enforces at most one active Owner. Service migrations add two guards:

- `private.guard_last_owner_role_change()` blocks revoking, replacing, or
  deleting the only active Owner assignment.
- `private.guard_last_owner_staff_deactivation()` blocks suspending or
  deactivating the last active Owner.

There is no ownership-transfer RPC or permission in the initial release.

## 4. RLS and grants

- RLS remains enabled on all public tables.
- Clients receive SELECT grants only where a policy exists, plus the approved
  low-risk customer self-profile UPDATE on `full_name`, `phone`, and
  `updated_at`.
- `private` and `authz` objects are not exposed through the Data API.
- `audit_events`, `exceptional_access_grants`, `permissions`, and
  `role_permissions` have no direct client access.
- Anonymous clients receive no table grants. Guest access is mediated by
  service-role Edge Functions and scoped RPCs.
- Financial reads (`session_discounts`, `bills`, `bill_orders`,
  `bill_discounts`, `payments`) are limited to Owner/Admin/Manager/Cashier.
- Waitlist reads are limited to the customer’s own entries or
  Owner/Admin/Manager branch roles. Cashier/Kitchen queue visibility is not
  approved and remains ungranted.

## 5. Implemented RPCs

### Organization and branch

- `register_organization(name, branch_name, branch_timezone, owner_display_name, ...)`
  — atomic organization, initial branch, Owner staff/role, and subscription;
  requires an active Free plan row; idempotent.
- `update_organization(organization_id, name)`.
- `create_branch(organization_id, name, timezone, ...)` — enforces the plan
  branch limit and Restricted state; idempotent.
- `update_branch(branch_id, name, timezone, ...)`.
- `deactivate_branch(branch_id, reason)` — rejects branches with active dining
  sessions.

### Staff

- `grant_staff_role(staff_id, role_code, scope_type, reason)` — Owner only may
  grant Admin; Owner role cannot be granted.
- `revoke_staff_role(assignment_id, reason)`.
- `assign_staff_branch(staff_id, branch_id)`.
- `revoke_staff_branch(assignment_id, reason)`.
- `deactivate_staff(staff_id, reason)`, `reactivate_staff(staff_id)`.
- `update_staff_profile(staff_id, display_name)`.

### Menu and tables

- Category, item, modifier group/option, and item-modifier assignment RPCs.
- Base price update and branch price override set/remove.
- Branch item availability.
- Table create/update/deactivate and QR regeneration.

### Sessions and guest tokens

- `resolve_or_create_dining_session(qr_public_id, token_hash_hex, device_label, expires_at)`
  — service role only; creates one active session per table; inserts the
  SHA-256 token hash. Restricted organizations cannot create sessions or issue
  new tokens.
- `validate_guest_token(token_hash_hex)` — service role only; existing tokens
  remain valid for viewing during Restricted.
- `get_guest_session_data(token_hash_hex)` — service role only; returns session
  context and persisted order summaries.
- `revoke_guest_token(token_id, reason)` — Owner/Admin/Manager branch role.

Order submission and lifecycle mutations are blocked; see §9.

### Waitlist

- `join_waitlist(...)` — customer-owned, one active entry per branch,
  server-side geolocation check when enabled, idempotent.
- `add_walk_in(...)`.
- `update_waitlist_status(...)` — waiting→notified/cancelled;
  notified→seated/cancelled/no-show.
- `cancel_waitlist_entry(...)`.
- `calculate_waitlist_position(...)` — FIFO by joined time; only own entry for
  customers.
- Manual reorder is not implemented; the algorithm is unapproved.

### Platform admin

- `list_organizations(page, page_size)`.
- `get_organization_metadata(organization_id)`.
- `suspend_organization(...)`, `reactivate_organization(...)`.

Exceptional-access grants, plan/entitlement management, and business-data access
remain blocked until the scope vocabulary and plan catalog are approved.

## 6. Idempotency

`private.idempotency_begin` serializes duplicates with a transaction-scoped
advisory lock, checks the request fingerprint, replays completed responses, and
returns `IDEMPOTENCY_CONFLICT` or `IDEMPOTENCY_IN_PROGRESS`. Implemented for
organization registration, branch creation, and waitlist join. Retention is
currently set per operation; the global retention policy remains pending.

## 7. Edge Functions

Implemented under `supabase/functions/`:

- `guest-resolve-table` — validates the public QR UUID, generates a 32-byte
  CSPRNG token, hashes it with SHA-256, calls the session RPC under service role,
  and returns the raw token once.
- `guest-reconnect` — validates an existing guest token and returns session
  context.
- `guest-session-data` — validates a guest token and returns persisted session
  and order summaries.

The functions import the canonical Zod contracts from `src/contracts/` and use
the shared success/error envelopes. `GUEST_TOKEN_TTL_SECONDS` is required; there
is no default because expiry duration is unapproved (`BLK-003`). Raw tokens are
never logged or persisted.

`guest-submit-order` is not implemented because menu availability semantics and
order transition rules are blocked.

## 8. Validation performed

- All 17 migrations (11 Agent 1 + 6 service) applied cleanly in order to a
  disposable PostgreSQL 18 database with mock `auth` functions and
  Supabase-like `anon`, `authenticated`, and `service_role` roles.
- Positive and negative checks passed for:
  - owner/admin/manager branch scope,
  - cross-branch denial,
  - cashier inability to create tables,
  - branch-limit enforcement,
  - last-Owner deactivation and role-revocation protection,
  - customer own-profile update and cross-customer denial,
  - anonymous table denial,
  - guest session resolution, token validation, and session-data read,
  - Restricted blocking new tokens while existing tokens remain valid,
  - waitlist join, duplicate rejection, position, and cancellation,
  - platform-admin listing and organization suspend/reactivate,
  - registration and branch-creation idempotent replay.
- TypeScript contracts typecheck and unit tests pass.
- Deno type-checks the three Edge Functions.
- Secret scan, blocker register, and RLS manifest static check pass.

## 9. Blockers preserved

| Blocker   | Not implemented                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------ |
| `BLK-001` | Tax/service/discount/rounding arithmetic; `preview_bill`, `finalize_bill`, payment recording     |
| `BLK-002` | Unapproved order/item transitions, cancellation billing effects, KDS notification behavior       |
| `BLK-003` | Guest token expiry duration, rotation, cleanup schedule (TTL is caller/env supplied; no default) |
| `BLK-004` | Waitlist restriction details, notification timing, no-show thresholds, manual reorder            |
| `BLK-005` | Granular role-to-permission mappings; `role_permissions` remains empty                           |
| `BLK-006` | Bill reopen/void/replacement workflow                                                            |
| `BLK-007` | Payment void/correction/refund/reconciliation                                                    |
| `BLK-008` | Realtime channel names, publication payloads, subscription filtering                             |

Additional schema-level blockers:

- Menu availability semantics (explicit opt-in vs default-available) are
  unresolved, so menu queries/order submission are not implemented.
- Plan catalog, entitlements, and grace-period values are unresolved; only an
  active Free plan row is required for registration.
- Staff invitation/activation flow is unresolved; no Auth-admin invitation Edge
  Function is implemented.
- Platform exceptional-access scope vocabulary is unresolved.
- Order display numbering is not implemented.
- Public menu access path is unresolved; no anonymous table grants exist.
- Realtime publication is not configured; `BLK-008`.
