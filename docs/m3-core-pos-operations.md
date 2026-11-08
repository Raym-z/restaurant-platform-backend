# M3 — Core POS Operations

## 1. Scope

M3 implements the backend foundation for staff POS operations:

- Branch-scoped table listing, detail, availability, and active-session reads.
- Transactional dining-session open, retrieve, list, and close.
- Transactional staff order creation and retrieval.
- Order-item add, quantity update, and removal before kitchen preparation.
- An explicit operational order state machine.
- Order cancellation with actor, timestamp, reason, and audit.
- Database-level guards, RLS-compatible reads, idempotency, and contracts.

Out of scope: POS frontend, guest ordering, payments, bills, discounts,
subscription changes, staff provisioning, KDS frontend, waitlist, and M2.1
branch-scoped role assignments.

## 2. Existing schema assessment

Reusable foundation tables:

| Area | Existing structures |
| --- | --- |
| Tenancy | `organizations`, `branches`, `subscriptions` |
| Access | `staff_profiles`, `staff_role_assignments`, `staff_branch_assignments` |
| Menu | `menu_categories`, `menu_items`, `branch_menu_categories`, `branch_menu_items`, `modifier_groups`, `modifier_options`, `menu_item_modifier_groups` |
| Tables | `restaurant_tables`, `table_qr_identifiers` |
| Sessions | `dining_sessions`, `private.guest_tokens` |
| Orders | `orders`, `order_items`, `order_item_modifiers` |
| Cross-cutting | `audit_events`, `private.idempotency_keys`, existing authz helpers |

Reusable invariants already present:

- One active dining session per table (`dining_sessions_one_active_per_table`).
- Composite tenant/branch foreign keys on tables, sessions, orders, and items.
- Guest-token hashes only, with revocation support.
- Pending/completed idempotency ledger with scoped uniqueness and request fingerprints.
- Audit events are append-only.
- Existing RLS grants staff branch-scoped reads and no direct order writes.

### 2.1 Initial RPC assessment

Existing reusable RPCs at M3 start:

- Menu administration: category/item/modifier CRUD and branch availability/pricing.
- Table administration: `create_table`, `update_table`, `deactivate_table`,
  `regenerate_table_qr`.
- Guest sessions: `resolve_or_create_dining_session`, `validate_guest_token`,
  `get_guest_session_data`, `revoke_guest_token`, `revoke_session_guest_tokens`.
- Organization, branch, staff, waitlist, and platform-admin RPCs.

Missing at M3 start and added here:

- Staff table list/detail/availability/active-session reads.
- Staff dining-session open/list/get/close.
- Order create/get/list by session/list by branch.
- Order item add/quantity update/remove.
- Order transition and cancellation RPCs.

Migration dependencies: the M3 migrations depend on the existing table/session
and order schema (`20261108090500`, `20261108090600`), audit/idempotency
(`20261108090900`), integrity guards (`20261108091000`), authz helpers
(`20261108100000`), idempotency helpers (`20261108100200`), and the existing
security-remediation helpers (`20261108100000`–`20261108110600`). They do not
depend on any M2 migration.

## 3. Schema additions

### `20261108110700_m3_order_schema_extensions.sql`

- Adds `completed` to `public.order_status` after `served`.
- Adds `orders.order_reference` with a stable `ORD-########` default.
- Adds `orders.completed_at`.
- Enforces global uniqueness of `order_reference` with a catalog-guarded
  constraint, so the file can be retried after a partial operational failure.

The enum addition is isolated in its own migration because PostgreSQL cannot use
a newly added enum value in the same transaction that added it.

### `20261108110800_m3_order_state_guards.sql`

- Replaces the order snapshot guard so subtotal can be recalculated only while
  an order is `pending` or `accepted`.
- Replaces the order-item snapshot guard so quantity is editable only while the
  parent order is `pending` or `accepted`; price/name snapshots stay immutable.
- Adds the database-level order transition trigger.
- Requires at least one non-cancelled item before an order can reach `served` or
  `completed`, so removing the last item cannot produce a fulfilled empty order.
- Adds the dining-session lifecycle trigger:
  - closed sessions cannot reopen;
  - closing requires a timestamp and staff member;
  - closing is blocked while non-terminal orders remain.

### `20261108110900_m3_pos_read_helpers.sql`

Private `SECURITY DEFINER` helpers with `search_path = ''` for order, item,
table, and session JSON plus authoritative menu pricing/availability.

It also adds `private.has_branch_history_access` /
`private.assert_branch_history_access`: active branches keep the existing
`authz.has_branch_access` rule, while inactive branches remain readable to active
organization-scoped staff in the same organization. Branch-scoped staff remain
bound to the active-branch rule, so deactivation never widens a branch-scoped
role. Writes still require an active branch through `authz.assert_branch_role`.
This helper is additive and does not modify the shared `authz` helpers used by
RLS.

### Availability and pricing resolution

M3 uses the existing branch override tables with this rule:

- archived items/categories are unavailable;
- an explicit `branch_menu_categories(is_available = false)` row blocks the category;
- an explicit `branch_menu_items(is_available = false)` row blocks the item;
- otherwise the item is available at the branch and inherits the organization price;
- an explicit branch price override is authoritative.

No client-submitted price or total is accepted. Modifier deltas and names are
snapshotted from `modifier_options` / `modifier_groups`.

## 4. Order state machine

Persisted states:

`pending -> accepted -> preparing -> ready -> served -> completed`

Terminal alternative: `cancelled`.

| From | To | Actor roles |
| --- | --- | --- |
| `pending` | `accepted` | owner, admin, manager, cashier |
| `accepted` | `preparing` | owner, admin, manager, kitchen_staff |
| `preparing` | `ready` | owner, admin, manager, kitchen_staff |
| `ready` | `served` | owner, admin, manager, cashier |
| `served` | `completed` | owner, admin, manager, cashier |
| `pending` / `accepted` / `preparing` / `ready` | `cancelled` | owner, admin, manager, cashier |

Notes:

- `accepted` is the existing database value for the wire-level “confirmed” step.
- `completed` is operational only. It does not imply payment settlement.
- `cancelled` and `completed` are terminal.
- Cancellation is performed by `cancel_order`, not the generic transition RPC.
- The transition trigger rejects any transition not listed above, including
  same-status transitions.
- Order transitions cascade to non-cancelled items. Reaching `served` or
  `completed` requires every non-cancelled item to be `served`; item-level
  independent KDS transitions remain deferred.
- An order with zero non-cancelled items cannot reach `served` or `completed`.
  Such an order must be cancelled. Removing the last item is allowed so staff can
  correct an order before cancelling it.
- `subtotalMinor` on an order is the immutable historical item snapshot. When an
  order is cancelled, `subtotalMinor` is retained for audit and
  `payableSubtotalMinor` becomes `0`. Session summaries already exclude cancelled
  orders from their payable total.

## 5. Authorization matrix

All RPCs derive identity and organization from the authenticated session. Client
organization/branch IDs are requests, not proof of access.

| Operation | Authorization |
| --- | --- |
| List/get tables, availability, active session | active staff with branch access; inactive branches: organization-scoped staff (read-only history) |
| List branch dining sessions | active staff with branch access; inactive branches: organization-scoped staff (read-only history) |
| Open/close dining session | branch role owner/admin/manager/cashier + active branch |
| Create order | branch role owner/admin/manager/cashier + active session + operational organization |
| Read orders | active staff with branch access; inactive branches: organization-scoped staff (read-only history) |
| Add/update/remove item | branch role owner/admin/manager/cashier + mutable order |
| Accept order | owner/admin/manager/cashier |
| Preparing / ready | owner/admin/manager/kitchen_staff |
| Served / completed | owner/admin/manager/cashier |
| Cancel order | owner/admin/manager/cashier + mandatory reason |
| Add item / increase quantity while restricted | blocked with `SUBSCRIPTION_RESTRICTED` / `ORGANIZATION_NOT_OPERATIONAL` |
| Reduce quantity, remove item, transition, cancel while restricted | allowed so existing work can be finished |

Existing helpers remain the primary authorization primitives:
`authz.require_staff_id`, `authz.current_organization_id`,
`authz.assert_branch_access`, `authz.assert_branch_role`,
`authz.assert_org_operational`, and `authz.acquire_org_shared_lock`.

M3 adds one scoped read helper, `private.assert_branch_history_access`, used only
by the read RPCs above. It does not change `authz.assert_branch_access` or RLS.
Cross-organization access is always denied because the branch must belong to the
caller's organization.

Historical reads after branch deactivation are available through these M3 RPCs
only. Direct PostgREST table reads remain subject to the existing RLS policies,
which still require an active branch, and therefore continue to deny inactive
branches.

## 6. RPC signatures

### Tables

```sql
public.list_branch_tables(p_branch_id uuid, p_include_inactive boolean default false) returns jsonb
public.get_table(p_table_id uuid) returns jsonb
public.get_table_availability(p_table_id uuid) returns jsonb
public.get_active_dining_session(p_table_id uuid) returns jsonb
```

### Dining sessions

```sql
public.list_branch_dining_sessions(
  p_branch_id uuid,
  p_status public.dining_session_status default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 20,
  p_offset integer default 0
) returns jsonb

public.open_dining_session(p_table_id uuid, p_idempotency_key text default null) returns jsonb
public.get_dining_session(p_session_id uuid) returns jsonb
public.close_dining_session(p_session_id uuid, p_reason text default null) returns jsonb
```

### Orders

```sql
public.create_order(
  p_dining_session_id uuid,
  p_items jsonb,
  p_notes text default null,
  p_idempotency_key text default null
) returns jsonb

public.get_order(p_order_id uuid) returns jsonb
public.list_orders_by_session(
  p_dining_session_id uuid,
  p_status public.order_status default null,
  p_limit integer default 20,
  p_offset integer default 0
) returns jsonb
public.list_branch_orders(
  p_branch_id uuid,
  p_status public.order_status default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 20,
  p_offset integer default 0
) returns jsonb

public.add_order_item(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_quantity integer,
  p_modifier_option_ids uuid[] default '{}'::uuid[],
  p_notes text default null
) returns jsonb

public.update_order_item_quantity(p_order_item_id uuid, p_quantity integer) returns jsonb
public.remove_order_item(p_order_item_id uuid, p_reason text default null) returns jsonb
public.transition_order_status(
  p_order_id uuid,
  p_status public.order_status,
  p_reason text default null
) returns jsonb
public.cancel_order(p_order_id uuid, p_reason text) returns jsonb
```

All RPCs return JSON objects using camelCase keys. Order detail includes item and
modifier snapshots. `subtotalMinor` is the historical item snapshot and
`payableSubtotalMinor` is the amount that may be settled (zero for cancelled
orders). List RPCs return `{ ..., pageSize, hasMore, nextOffset }` with offset
pagination capped at 100 rows. Session order lists are oldest-first; branch order
and session lists are newest-first. All lists use a stable UUID secondary sort.

## 7. Error codes

Existing codes reused: `VALIDATION_ERROR`, `BRANCH_NOT_FOUND`,
`BRANCH_ACCESS_DENIED`, `PERMISSION_DENIED`, `STAFF_NOT_ACTIVE`,
`TABLE_NOT_FOUND`, `MENU_ITEM_NOT_FOUND`, `MENU_ITEM_UNAVAILABLE`,
`INVALID_MENU_PRICE`, `INVALID_MODIFIER_SELECTION`, `ORDER_NOT_FOUND`,
`ORDER_INVALID_STATUS`, `ORDER_MODIFICATION_NOT_ALLOWED`, `ORDER_EMPTY`,
`ORDER_ITEM_QUANTITY_INVALID`, `SESSION_NOT_ACTIVE`,
`SESSION_ALREADY_CLOSED`, `SESSION_BALANCE_OUTSTANDING`,
`SUBSCRIPTION_RESTRICTED`, `ORGANIZATION_NOT_OPERATIONAL`,
`IDEMPOTENCY_CONFLICT`, `RESOURCE_CONFLICT`.

Added by M3: `DINING_SESSION_NOT_FOUND`, `ORDER_ITEM_NOT_FOUND`.

`RESOURCE_CONFLICT` is used for occupied tables and inactive-table session opens.
`SESSION_BALANCE_OUTSTANDING` is used when non-terminal orders block session close.

## 8. Idempotency

`open_dining_session` and `create_order` accept optional idempotency keys.

- Scope: `staff`, actor staff ID.
- Operations: `dining_session.open`, `order.create`.
- Fingerprints: SHA-256 of canonical request content (`jsonb::text` for items).
- Replay returns the original response.
- Reusing a key with different content raises `IDEMPOTENCY_CONFLICT`.
- Concurrent duplicates serialize on the existing advisory lock.
- Replay is authorized first; an unauthenticated caller cannot retrieve a stored
  response.

## 9. Concurrency and locking

- Organization advisory lock: shared for POS operations; exclusive for suspension.
- Open session: organization advisory -> branch row -> table row -> session row.
- Close session: organization advisory -> table row -> session row.
- Order writes after creation: order row -> dining-session share lock.
- `create_order` itself has no pre-existing order row to lock: it takes the
  dining-session share lock first, then inserts the order row. Closing the
  session waits for that insert; after commit, close sees the new order and
  fails with `SESSION_BALANCE_OUTSTANDING`.
- `add_order_item` takes the organization advisory lock before the order row and
  session share lock. `update_order_item_quantity` locks the order/item rows
  first and checks the organization only when quantity increases; no conflicting
  path holds an order row while taking the exclusive organization lock, so this
  cannot deadlock with suspension. Reductions, removals, transitions, and
  cancellation do not take the organization lock.
- Session close takes the session exclusive lock, so it waits for in-flight
  order writes, and order writes wait for close.
- Unique partial index remains the final defence against duplicate active sessions.
- `orders_guard_status_transition` is the final defence against invalid state changes.

## 10. Audit

Critical mutations write `public.audit_events` through `private.audit_write`:

- `dining_session.opened`
- `dining_session.closed`
- `order.created`
- `order.item_added`
- `order.item_quantity_updated`
- `order.item_removed`
- `order.status_changed`
- `order.cancelled`

Audit rows include organization, branch, actor staff ID, target, reason where
relevant, and non-sensitive metadata.

## 11. Realtime

Supabase Realtime publication remains unconfigured (`BLK-008`). M3 does not add a
publication or channel contract because channel names, payloads, and filtering
are not approved. Persisted tables remain authoritative. Clients must recover by
re-reading through the authorized RPCs. Do not enable Realtime on `orders`,
`dining_sessions`, or tables without a reviewed tenant/branch subscription design.

## 12. M2 integration boundary

M3 does not depend on M2 and does not modify role assignments. The M3 read helper
added here (`private.assert_branch_history_access`) is additive and only checks
organization-scoped assignments, so it remains valid before and after M2.1
branch-scoped role assignments.

M2.1 (`20261108120000_m2_branch_scoped_staff_roles.sql`) replaces
`authz.has_branch_access`, `authz.has_branch_role`, and `authz.has_permission`
with branch-aware versions and adds `staff_role_assignments.branch_id`. M3 only
calls these helpers by their existing signatures, so the combined sequence
`main -> M3 (110700-111100) -> M2.1 (120000)` applies cleanly. M3 explicit role
arrays remain valid: organization-scoped roles keep organization-wide reach and
branch-scoped roles are restricted to their assigned active branch.

Future branch-specific role semantics should be integrated only inside the
existing `authz` helper layer (`has_branch_role`, `has_branch_access`,
`assert_branch_role`, `assert_branch_access`, `assert_org_operational`) or by
replacing the explicit role arrays in these RPCs with an approved permission
helper. No M3 RPC signature or table contract should need to change.

Do not add `branch_id` to `staff_role_assignments` as part of M3, and do not
introduce a parallel permission model.

## 13. Known limitations

- Independent item-level KDS transitions are not implemented. Order-level
  transitions cascade to non-cancelled items, order `served`/`completed`
  requires at least one non-cancelled item and every such item to be `served`,
  and cancellation terminates remaining items.
- Removal is a soft item cancellation so historical snapshots remain auditable.
  Removing the last active item leaves a zero-item order that can only be
  cancelled; it cannot reach `served` or `completed`.
- Cancelled orders retain their historical `subtotalMinor`; consumers must use
  `payableSubtotalMinor` (zero when cancelled) and exclude cancelled orders from
  session/bill totals.
- Closing a session requires all orders to be `completed` or `cancelled`; because
  payment/billing is out of scope, “settled” is represented only by operational
  terminal state.
- Historical reads after branch deactivation are allowed to active
  organization-scoped staff only. Branch-scoped staff remain denied on an
  inactive branch; extending history access to them would require a coordinated
  change in the shared authz helper layer plus M2.1 review.
- Realtime is not configured (`BLK-008`). Current RPCs remain correct because
  PostgreSQL is authoritative; clients must poll/refetch until a reviewed
  tenant/branch subscription design exists.
- Per-branch human order display numbering remains deferred; `order_reference`
  is stable but not a per-branch sequence.
- Database integration tests were executed against a disposable local PostgreSQL
  instance; they were not run against the Supabase CLI stack in this environment.
