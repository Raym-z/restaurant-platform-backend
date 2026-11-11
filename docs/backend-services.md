# Backend Services Implementation

This document describes the backend-services workstream implementation: RLS,
grants, authorization helpers, RPCs, Edge Functions, and related contracts. It
does not redefine approved business rules. Unapproved decisions remain blocked
and are listed in §9.

## 1. Ownership and migration order

Agent 1 owns the schema foundation. Agent 2 owns RLS, grants, authorization
helpers, RPCs, backend service migrations, Edge Functions, and shared contracts.

Service migrations follow the Agent 1 baseline and are additive:

| Migration                                                              | Purpose                                                                                                                                 |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `20261108100000_authz_helpers.sql`                                     | `authz` helper schema, staff/customer/platform-admin resolution, role/scope checks, subscription gates, audit writer, last-Owner guards |
| `20261108100100_rls_policies.sql`                                      | SELECT policies, approved customer self-profile update, client grants                                                                   |
| `20261108100200_idempotency_helpers.sql`                               | Scoped idempotency begin/complete/fail helpers                                                                                          |
| `20261108100300_rpc_organization_branch_staff.sql`                     | Organization, branch, and staff RPCs                                                                                                    |
| `20261108100400_rpc_menu_tables_sessions.sql`                          | Menu, table, QR, dining-session, and guest-token RPCs                                                                                   |
| `20261108100500_rpc_waitlist_platform.sql`                             | Waitlist and platform-admin metadata RPCs                                                                                               |
| `20261108110000_security_remediation_foundation.sql`                   | SHA-256 fingerprints, rate limiting, organization status, session context guard, plan visibility                                        |
| `20261108110100_security_remediation_rpcs.sql`                         | Organization/branch/table/session locking, audit, and status enforcement                                                                |
| `20261108110200_security_remediation_waitlist.sql`                     | Waitlist concurrency/rate limiting and session-wide token revocation                                                                    |
| `20261108110300_security_remediation_error_consistency.sql`            | Cross-tenant not-found normalization for organization, branch, and table updates                                                        |
| `20261108110400_security_remediation_phase2.sql`                       | Organization locking, missing-subscription fail-closed, session lock, rate-limit retention, platform-admin plan access                  |
| `20261108110500_security_remediation_error_consistency_menu_staff.sql` | Cross-tenant not-found normalization for menu and staff administration RPCs                                                             |
| `20261108110600_security_remediation_phase2_fixes.sql`                 | Advisory org locks, safe rate-limit cleanup, waitlist lock order, token-validation/revocation locking, customer bucket hashing          |
| `20261108110700_m3_order_schema_extensions.sql`                        | M3: `completed` order status, stable `order_reference`, `completed_at`, guarded reference uniqueness                                    |
| `20261108110800_m3_order_state_guards.sql`                             | M3: order/item snapshot and transition guards, terminal-state item requirements, dining-session closure guard                          |
| `20261108110900_m3_pos_read_helpers.sql`                               | M3: private POS read/pricing helpers, including inactive-branch history access                                                          |
| `20261108111000_m3_table_session_rpcs.sql`                             | M3: table availability and dining-session read/open/close RPCs                                                                         |
| `20261108111100_m3_order_rpcs.sql`                                     | M3: transactional order create/get/list, item modification, transition, and cancellation RPCs                                        |
| `20261108120000_m2_branch_scoped_staff_roles.sql`                       | Per-branch role assignments, deterministic legacy backfill, branch-aware authz helpers, branch-aware grant/revoke RPCs                  |
| `20261109120000_m2_branch_scoped_staff_roles_fixes.sql`                 | Conflict-safe branch-assignment consistency trigger, serialized role revocation, branch/organization FK index                          |
| `20261109130000_m2_staff_rpc_concurrency_and_errors.sql`                | Branch-revocation serialization, role-revocation lock order, backfill SHARE lock, permission branch validation, normalized errors     |
| `20261109140000_m2_staff_admin_error_normalization.sql`                 | Missing/cross-tenant normalization for staff deactivation, reactivation, and profile updates                                          |
| `20261109140100_m3_order_insert_terminal_state_guard.sql`               | M3: defense-in-depth `BEFORE INSERT` terminal-state guard for privileged order inserts                                                 |
| `20261109150000_m4_kitchen_infrastructure.sql`                          | M4.1: branch-scoped kitchen stations, category/item menu routing, kitchen tickets and ticket items, RLS and read grants                 |
| `20261109160000_m4_kitchen_ticket_lifecycle.sql`                        | M4.2: ticket generation, independent item lifecycle, aggregation, cancellation propagation, audit, and KDS transition RPCs             |
| `20261109170000_m4_kitchen_ticket_lifecycle_corrections.sql`            | M4.2 corrections: generation identity, exact aggregate guards, staff/system cancellation actors, completed-item protection, routing diagnostics |
| `20261109180000_m4_kitchen_ticket_lifecycle_final_corrections.sql`      | M4.2 final corrections: preparing/ready item removal, direct item aggregate trigger, cancelled-ticket insertion guard, attribution immutability |
| `20261110120000_m4_kitchen_station_management.sql`                      | M4.3: station and routing management RPCs, authorization, and audit                                                                     |
| `20261110130000_m4_kitchen_kds_read_rpcs.sql`                           | M4.3: bounded KDS ticket list/detail RPCs with order, table, item, and modifier context; no financial fields                            |
| `20261110140000_m4_realtime_kitchen_publication.sql`                    | M4.3: kitchen Realtime publication and route-table replica identity; delivery verification remains blocked (`BLK-008`)                  |
| `20261110150000_m4_order_kitchen_state_policy.sql`                      | M4.3: order-level preparing/ready restricted to Owner/Admin/Manager; Kitchen Staff use kitchen RPCs                                     |

Agent 1 migrations are never edited.

**Combined M2.1 + M3 history:** M2 and M3 originally both used timestamp
`20261109140000`. The integration branch keeps M2's
`20261109140000_m2_staff_admin_error_normalization.sql` at its original name and
renumbers the independent M3 terminal-state guard to
`20261109140100_m3_order_insert_terminal_state_guard.sql` (SQL unchanged). This
restores a unique, strictly increasing migration sequence. Apply the full set
through `20261109140100`; the M3 guard has no dependency on M2 and sorts safely
last.

**Minimum migration range:** Apply every M2 migration through
`20261109140000_m2_staff_admin_error_normalization.sql`, which includes
`20261109130000_m2_staff_rpc_concurrency_and_errors.sql`. Do **not** stop at
`20261109120000_m2_branch_scoped_staff_roles_fixes.sql`: that leaves the earlier
`revoke_staff_role` lock order in place (role row lock before the organization
advisory lock) and retains the grant-vs-revoke deadlock risk. The final F2
lock-order correction is in `20261109130000`; `20261109140000` adds the staff
administration error normalization.

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
  assignment and an active branch assignment for the same branch are both
  required.
- A branch-scoped role applies only at `staff_role_assignments.branch_id`.
  Holding Manager at Branch A never grants Manager at Branch B.
- Organization-scoped roles ignore branch assignment reach and apply to every
  active branch in the organization.
- Revoked role assignments, revoked branch assignments, inactive staff, and
  inactive branches all deny access.

`authz.has_branch_access(uuid)`, `authz.has_branch_role(uuid, text[])`, and
`authz.has_permission(text, uuid)` are the branch-aware resolution points.
`authz.has_org_role(text[])` remains deliberately organization-scope-only, so a
branch-scoped Admin does not gain organization administration rights.
For an organization-scoped permission check, a non-null `p_branch_id` must
identify an active branch in the staff member's organization; a null branch means
the caller is checking an organization-wide permission without branch context.
Branch-scoped permission checks always require the matching active branch and an
active branch assignment.

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

- `grant_staff_role(staff_id, role_code, scope_type, reason, branch_id)` —
  Owner only may grant Admin; Owner role cannot be granted. Branch-scoped roles
  require `branch_id` in the caller's organization and atomically ensure an
  active branch assignment for that staff/branch. Organization-scoped grants
  must omit `branch_id`. The response is
  `{assignmentId, staffId, roleCode, scope, branchId}`.
- `revoke_staff_role(assignment_id, reason)` — revocation is audited with the
  assignment's branch context and takes effect immediately.
- `assign_staff_branch(staff_id, branch_id)`.
- `revoke_staff_branch(assignment_id, reason)`.
- `deactivate_staff(staff_id, reason)`, `reactivate_staff(staff_id)`.
- `update_staff_profile(staff_id, display_name)`.

### Staff invitations

- `create_staff_invitation(email, display_name, role_code, scope_type, branch_id,
  token_hash_hex, expires_at, reason)` — Owner/Admin only. Owner may invite
  Admin; Admin may invite Manager, Cashier, or Kitchen Staff. The RPC validates
  role/scope rules, branch ownership and active state, duplicate pending
  invitations, and existing same-organization membership. It stores only the
  SHA-256 token hash.
- `list_staff_invitations(limit)` — Owner/Admin only. Recent invitations for the
  caller organization, with token hashes excluded and expiry derived at read
  time.
- `revoke_staff_invitation(invitation_id, reason)` — Owner/Admin only. Accepted
  invitations cannot be revoked; an already-revoked invitation is idempotent.
- `rotate_staff_invitation_token(invitation_id, token_hash_hex, expires_at)` —
  Owner/Admin only. Resends rotate the token, invalidating the previous link.
- `accept_staff_invitation(token_hash_hex)` — authenticated invitee only. The
  authenticated Auth-user email must match the invitation, the inviter's current
  authority is revalidated, and membership plus the role assignment are created
  in one transaction. Replay returns `INVITATION_ALREADY_ACCEPTED`.

The raw acceptance token is generated by the `staff-invite` Edge Function and is
never stored in the database, logs, or the POS. Auth Admin operations
(`inviteUserByEmail`) run only inside that function; the service-role key never
reaches the browser.

`register_organization` requires an active Free plan. The M4.7.2 migration adds
one conservative `free` plan (`branch_limit = 1`) only when no active Free plan
exists. Existing plan rows are never updated or deleted; commercial entitlements
remain a product decision.

Missing and cross-tenant staff IDs share the same `Staff member was not found`
detail for `deactivate_staff`, `reactivate_staff`, and `update_staff_profile`.
Authorization is still enforced before any mutation.

Branch-scoped authorization still requires both the role row and an active
branch assignment. A database trigger records the branch assignment whenever
an active branch-scoped role is inserted, so direct SQL and RPC provisioning
remain consistent. The trigger uses `ON CONFLICT DO NOTHING` against the active
branch-assignment unique index, so concurrent grants of different roles at the
same branch do not produce a false role conflict. Concurrent role revocations
and concurrent branch-assignment revocations lock the assignment row and write a
single audit event; the second caller returns `already_revoked`. Revocation RPCs
resolve the actor, validate the target organization, and acquire the
organization advisory lock before locking the assignment row, consistent with
the documented organization → row lock order.

**Lifecycle semantics:** revoking a branch assignment is a suspension, not a
permanent role removal. The role row remains active but is denied while the
assignment is revoked. Re-assigning the same branch restores that still-active
role. To remove access permanently, revoke the role assignment itself (and
optionally the branch assignment). The same applies to branch deactivation: a
role on an inactive branch is inert and becomes effective again if the branch
is reactivated.

**Assigning a branch does not grant a role.** `assign_staff_branch` only
records the branch assignment; it does not extend an existing branch-scoped
role to the newly assigned branch. Grant the role for that branch explicitly.
A branch assignment without any matching role grants no authorization and no
branch visibility.

**Implicit branch-assignment audit:** when a branch-scoped role grant creates
the matching active branch assignment, `staff.role_granted` is the authoritative
audit event. It records the branch in the event's `branch_id` column and in
`metadata.branch_id` and `metadata.scope_type`. No separate
`staff.branch_assigned` event is emitted for that implicit creation; an explicit
`assign_staff_branch` call still emits its own `staff.branch_assigned` event.
The role-grant event and the assignment are written in the same transaction.

**Inactive-branch grants:** `grant_staff_role` validates organization
membership but does not currently reject inactive branches. A branch role
granted on an inactive branch is inert until the branch is reactivated. Treat
this as pre-provisioning; do not present it as active access in the POS UI.

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

M3 adds staff order submission, item modification, lifecycle transitions, and
cancellation. Guest order submission remains out of scope; see
`docs/m3-core-pos-operations.md`.

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

`guest-submit-order` is not implemented. M3 implements the staff POS order path
and documents its branch availability rule in
`docs/m3-core-pos-operations.md`; guest ordering remains a separate milestone.

## 7.1 Security remediation behavior

### Organization operational status

- `active`: normal authorized operations.
- `suspended`: staff/guest operational mutations are blocked with
  `ORGANIZATION_NOT_OPERATIONAL`; RLS historical reads remain available;
  existing guest tokens are rejected.
- `pending_deletion`: new operational mutations are blocked; historical reads
  and existing guest-session reads remain available; new guest sessions/tokens
  are blocked.
- `deleted_at` set: treated as non-operational.
- `restricted` subscription state: existing guest sessions remain readable; new
  sessions/tokens and new orders are blocked.

The checks are centralized in `authz.organization_is_operational`,
`authz.organization_allows_guest_session`, and
`authz.assert_org_operational`. A `dining_sessions` insert trigger rechecks
table, branch, and organization status as defense in depth.

Operational mutations take a shared transaction-scoped advisory lock keyed by
organization; suspension/pending deletion takes an exclusive keyed advisory
lock. Shared operations run concurrently and suspension waits for in-flight
operations. Branch, table, and dining-session row locks are acquired only after
the organization lock. Guest token validation takes the org shared lock plus a
share lock on the dining-session row; session-wide revocation takes the
exclusive dining-session lock. Missing subscription records fail closed as
`restricted`; the resulting operational error is consistently
`SUBSCRIPTION_RESTRICTED`. Authorization/status failures use
`ORGANIZATION_NOT_OPERATIONAL`.

### Rate limiting

`public.consume_rate_limit(policy, bucket_suffix)` is a service-role RPC backed
by `private.rate_limit_policies` and `private.rate_limit_buckets`. Consumption
is atomic and works across Edge Function instances. Default seeded policies:

| Policy                   | Attempts | Window |
| ------------------------ | -------: | -----: |
| `guest_resolve_ip`       |       10 |    60s |
| `guest_resolve_qr`       |       60 |    60s |
| `guest_reconnect_ip`     |       60 |    60s |
| `guest_session_ip`       |      120 |    60s |
| `guest_token`            |      120 |    60s |
| `waitlist_join_customer` |       10 |  3600s |

Edge Functions return HTTP 429 with `Retry-After`. `join_waitlist` enforces the
customer policy server-side in SQL. These defaults are security controls and
can be tuned without changing business rules.

IP-derived buckets are HMAC-SHA-256 hashes; raw IPs are never stored. Required
Edge configuration:

- `RATE_LIMIT_HASH_SECRET` — at least 32 characters; required, otherwise the
  guest functions fail closed.
- `TRUSTED_CLIENT_IP_HEADER` — optional; one of `cf-connecting-ip`,
  `x-real-ip`, or `x-forwarded-for`. Only set this when the deployed platform
  guarantees the header is overwritten/authenticated.
- `TRUSTED_PROXY_HOPS` — positive integer, default 1, used to select the
  correct `x-forwarded-for` entry from the right.

If no trusted header is configured, the direct peer address from
`Deno.serve` connection info is used. If that is unavailable or malformed, all
such requests share a single `unknown` bucket (safe fallback, but coarse).
Gateway header behavior is a deployment assumption and is not verified by this
repository.

Rate-limit retention is separate from guest-token cleanup (`BLK-003`). Call
`public.cleanup_rate_limit_buckets(retention_seconds)` from a scheduled job
(recommended daily; minimum retention 60 seconds). The default is 86,400
seconds. Cleanup deletes only buckets whose policy window has fully expired and
whose expiry is older than the retention interval; an active hourly window is
never deleted merely because the retention interval is short.

Waitlist rate-limit buckets hash the customer UUID as
`private.sha256_hex('customer:' || customer_id::text)`; the raw customer UUID
is not stored in the bucket key.

### Timestamps

Contract timestamps accept `Z` or numeric offsets and normalize to UTC `Z`.
This matches PostgreSQL/PostgREST `timestamptz` serialization.

### Guest token revocation

`public.revoke_session_guest_tokens(session_id, reason)` revokes every active
token for a session with branch-role authorization and audit logging. Audit
records contain session/token identifiers and expiry but never raw tokens or
hashes.

### Deferred

- Guest token expiry duration, rotation, and cleanup remain `BLK-003`.
- Device binding remains a bearer-token design limitation.
- Session closure and full settlement remain blocked by billing rules.
- RLS coverage manifest population remains owned by the testing infrastructure;
  the security integration tests cover the key RLS paths but do not populate the
  manifest. Populating it without per-table pgTAP tests would overstate
  coverage, so it is deferred for Agent 3 coordination.
- Direct RPC callers must map `RATE_LIMIT_EXCEEDED` to HTTP 429 themselves;
  Edge Functions already return 429 with `Retry-After`.

## 8. Validation performed

- All 34 combined M2.1 + M3 migrations applied cleanly to disposable
  PostgreSQL 18 databases in three sequences: natural filename order,
  M2.1-then-M3, and M3-then-M2.1. Each database used mock `auth` functions and
  Supabase-like `anon`, `authenticated`, and `service_role` roles.
- The full integration suite (74 tests across 15 files) passed serially against
  all three migration-order databases, covering M2.1 branch-scoped roles, M2
  concurrency/lock-order, cross-tenant errors, backfill locking, M3 table/session
  and order/terminal-state behavior, RLS, and helper grants.
- Retry-safe migrations (`20261108110700`, `20261109140000`, and
  `20261109140100`) re-applied cleanly. Catalog checks confirmed RLS on all 38
  public tables, no `private` function execution for `anon`/`authenticated`, and
  consistent `staff_role_assignments` branch scoping.
- Official local Supabase (Docker) validation remains outstanding on this
  machine because the Docker WSL 2/Virtual Machine Platform backend is
  unavailable. Consequently `supabase db reset`, `supabase db lint`, pgTAP
  database tests, pgTAP-based RLS manifest population, and Edge Function tests
  were not executed and must run in an environment with official Supabase
  infrastructure before approval.
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
- Security remediation regression tests:
  - timestamp offset normalization,
  - Edge body-size and `Retry-After` handling,
  - DB-backed rate limits including concurrent consumption,
  - concurrent branch creation against a plan limit,
  - session creation versus table and branch deactivation,
  - revoked-QR rejection,
  - suspended/pending-deletion authorization and guest-token behavior,
  - SHA-256 idempotency fingerprint length and different-payload conflict,
  - concurrent waitlist cancellation,
  - waitlist join rate limiting,
  - cross-tenant not-found consistency for tables, guest tokens, and waitlist,
  - session-wide guest-token revocation and audit without token material,
  - staff-only plan visibility, platform-admin plan visibility, and revoked helper execution,
  - spoofed/duplicated/missing/malformed IPv4 and IPv6 client identities,
  - strict timestamp validation for invalid dates, 24:00, leap days, six-digit fractions, and invalid offsets,
  - organization suspension versus branch creation and guest-token validation,
  - missing subscription fail-closed behavior,
  - consistent `SUBSCRIPTION_RESTRICTED` / `ORGANIZATION_NOT_OPERATIONAL` codes,
  - normalized menu/staff cross-tenant errors,
  - normalized staff deactivation/reactivation/profile-update cross-tenant errors,
  - migration 120000 SHARE lock before the legacy backfill,
  - implicit branch-assignment audit policy,
  - branch-revocation organization-lock ordering,
  - normalized idempotency values,
  - session-wide revocation versus concurrent token issuance,
  - safe rate-limit bucket retention (active windows preserved, expired windows cleaned),
  - concurrent shared organization operations not blocking each other,
  - advisory organization lock serialization with suspension,
  - customer UUID bucket hashing,
  - `add_walk_in` cross-tenant not-found consistency,
  - token validation versus session-wide revocation serialization.
- TypeScript contracts typecheck and unit tests pass.
- Deno type-checks the three Edge Functions.
- Secret scan, blocker register, and RLS manifest static check pass.
- Edge HTTP runtime, PostgREST RLS, and browser CORS remain unverified because
  Docker/Edge HTTP is unavailable; those tests are not claimed as passed.

## 9. Blockers preserved

| Blocker   | Not implemented                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------ |
| `BLK-001` | Tax/service/discount/rounding arithmetic; `preview_bill`, `finalize_bill`, payment recording     |
| `BLK-002` | Cancellation billing effects and guest-facing KDS notifications                           |
| `BLK-003` | Guest token expiry duration, rotation, cleanup schedule (TTL is caller/env supplied; no default) |
| `BLK-004` | Waitlist restriction details, notification timing, no-show thresholds, manual reorder            |
| `BLK-005` | Granular role-to-permission mappings; `role_permissions` remains empty                           |
| `BLK-006` | Bill reopen/void/replacement workflow                                                            |
| `BLK-007` | Payment void/correction/refund/reconciliation                                                    |
| `BLK-008` | Realtime branch-isolation and delivery verification (publication contract implemented)            |

Additional schema-level blockers:

- Menu availability semantics remain unresolved for public/guest menu queries.
  M3's staff order path uses a documented explicit-override/default-available
  rule in `docs/m3-core-pos-operations.md`.
- Plan catalog, entitlements, and grace-period values are unresolved; only an
  active Free plan row is required for registration.
- Staff invitation/account provisioning is implemented in M4.7.2 through the
  `staff-invite` Edge Function and the invitation RPCs above. Deployment still
  requires Auth email/SMTP and redirect-URL configuration.
- Platform exceptional-access scope vocabulary is unresolved.
- Per-branch order display numbering is not implemented. M3 adds a stable,
  non-sequential `order_reference` for operational correlation.
- Public menu access path is unresolved; no anonymous table grants exist.
- Realtime publication is configured for the five kitchen tables in M4.3, but
  branch-isolation and delivery tests could not run without Docker/WSL. `BLK-008`
  remains open and polling is the supported fallback.
