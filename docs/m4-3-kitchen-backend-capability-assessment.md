# M4.3.1 — Kitchen Backend Capability Assessment

**Assessment type:** read-only source review  
**Date:** 2026-11-10  
**Repository:** `restaurant-platform-backend`  
**Worktree:** `restaurant-platform-backend-m4-1`  
**Branch:** `feature/m4-1-kitchen-infrastructure`  
**HEAD verified:** `a1a4e5edc994b45d1066b28454a6149dba784b34`  
(`a1a4e5e`, `feat(kitchen): implement M4.2 ticket lifecycle`)  
**Working tree at assessment start:** clean

> **Implementation status (2026-11-10):** M4.3 implements T1 (contracts and
> kitchen error codes), T2 (KDS read RPCs), T3 (station/routing management), T4
> (Realtime publication and contract; verification blocked by unavailable
> Docker/WSL), T5 (order-versus-kitchen ownership policy), and T7 (documentation
> and blocker register). T8 static checks pass; database integration,
> clean-database migration validation, and Realtime branch-isolation tests are
> **blocked** in this environment and are not claimed as passed. The findings
> below remain the baseline that guided the implementation.

This assessment inspects the actual migrations, SQL functions, triggers, grants,
RLS policies, contracts, tests, and documentation. It does not start a database,
apply migrations, or modify repository state. Runtime behavior that requires a
database or Realtime server is marked **Not Verified** where relevant.

---

## 1. Executive summary

M4.1 and M4.2 provide a credible **write-side** KDS foundation:

- Branch-scoped kitchen stations, category/item menu routing, kitchen tickets, and
  ticket items.
- Generation of one ticket per `(order, station)` on order acceptance, including
  item additions and fresh generations after cancellation.
- Independent ticket-item preparation state:
  `pending → preparing → ready → completed`, plus cancellation.
- Exact aggregate-status derivation and guards.
- Order and order-item cancellation propagation.
- Staff/system cancellation attribution with immutable attribution once recorded.
- Branch-scoped RLS with `SELECT`-only client access.
- Three client transition RPCs and one read-only routing diagnostics RPC.
- Real two-session concurrency tests for generation and completion-vs-removal.

The backend is **not yet sufficient for a production-quality KDS frontend**
without M4.3 work. The main gaps are:

1. **No KDS read API/contract.** There is no `list_kitchen_tickets` or
   `get_kitchen_ticket` RPC. Authenticated clients can read the tables directly
   through RLS, but there is no contract-shaped, bounded, single-round-trip view
   containing station name, table label, order context, items, modifiers, and
   ticket/item timestamps. `kitchen_ticket_item_json` omits modifiers and order
   context; `get_order` omits table label and kitchen ticket context.
2. **No station or routing management RPCs.** Stations and routes can only be
   written by a privileged database owner. There is no client-side
   create/update/deactivate/reactivate station path and no route set/remove path.
   A production KDS cannot be configured through the application today.
3. **Realtime is not configured.** There is no publication membership and no
   replica-identity configuration. `BLK-008` remains open. Realtime RLS behavior
   is therefore **Not Verified**.
4. **No ticket-level conveniences.** There is no ticket acknowledgement, priority,
   recall/reopen, station transfer, or kitchen-side individual item cancellation.
   Most of these are reasonable M4.4+ decisions rather than M4.3 requirements.
5. **Order state and kitchen state can diverge by design.** M3 order transitions
   cascade only to `order_items.status`; M4.2 kitchen state is independent.
   Kitchen staff can still call `transition_order_status` for
   `accepted → preparing → ready`. M4.3/M4.4 must decide which state is
   authoritative for which UI.
6. **Shared contract gaps.** Kitchen SQL error codes
   (`KITCHEN_INVALID_TRANSITION`, `KITCHEN_TICKET_ITEM_NOT_FOUND`,
   `KITCHEN_TICKET_CANCELLED`, `KITCHEN_TICKET_INCONSISTENT`,
   `KITCHEN_CANCELLATION_INVALID`) are not in `API_ERROR_CODES`, and there are no
   request/response contracts for ticket listing or station management.

**Security conclusion:** no client-reachable critical or high-severity defect was
found. Cashier and anonymous access to kitchen tables is denied; cross-branch
access is denied by RLS and RPC checks; cross-organization access does not reveal
record existence; direct writes are denied. The security-sensitive work in M4.3
is adding Realtime publication **with RLS verification**, not repairing an
existing client-reachable hole.

**Recommendation:** M4.3 should implement (a) shared contracts and kitchen error
codes, (b) KDS read RPCs, (c) station/routing management RPCs, and (d) the
Realtime publication/subscription contract with RLS tests. M4.4 can then build
the KDS against stable contracts. Polling-only KDS work can begin after (a) and
(b), but production realtime requires (d).

---

## 2. Current implementation inventory

### 2.1 Schema

Source: `supabase/migrations/20261109150000_m4_kitchen_infrastructure.sql` and
`20261109160000_m4_kitchen_ticket_lifecycle.sql`,
`20261109170000_m4_kitchen_ticket_lifecycle_corrections.sql`,
`20261109180000_m4_kitchen_ticket_lifecycle_final_corrections.sql`.

| Object | Purpose | Key constraints / indexes |
| --- | --- | --- |
| `public.kitchen_stations` (`20261109150000:25-56`) | Branch-scoped station with `active`/`inactive` status and `deactivated_at`. | `(branch_id, lower(btrim(name)))` unique (`:49-50`); `(branch_id, status)` index (`:52-53`); status/timestamp check (`:37-40`). |
| `public.kitchen_station_menu_categories` (`:64-88`) | Category-level routing. | `(station_id, menu_category_id)` unique (`:72-73`); branch/station and org/category FKs (`:74-82`). |
| `public.kitchen_station_menu_items` (`:96-120`) | Item-level routing, taking precedence over category routing. | `(station_id, menu_item_id)` unique (`:104-105`); branch/station and org/item FKs (`:106-113`). |
| `public.kitchen_tickets` (`:128-176`) | One active ticket per `(order, station)`, plus historical cancelled generations. | Unique `(order_id, station_id, generation)` (`20261109170000:32-33`); partial unique active ticket (`:73-75`); branch/status/created and station/status/created indexes (`20261109150000:169-173`). |
| `public.kitchen_ticket_items` (`:191-215`) | Links tickets to immutable `order_items` snapshots; holds independent kitchen status. | `(ticket_id, order_item_id)` unique (`:199-200`); `(ticket_id, status)` index (`20261109160000:47-48`); composite FKs prevent cross-order/cross-tenant links (`20261109150000:201-208`). |

Enums: `kitchen_station_status` (`active`, `inactive`) and
`kitchen_ticket_status` (`pending`, `preparing`, `ready`, `completed`,
`cancelled`) at `20261109150000:9-20`.

M4.2 additions:

- `kitchen_ticket_items.status`, `started_at`, `ready_at`, `completed_at`,
  `cancelled_at`, `cancelled_by_staff_id`, `cancellation_reason`, `updated_at`
  (`20261109160000:23-31`).
- `kitchen_ticket_items.cancelled_by_actor_type` and
  `kitchen_tickets.cancelled_by_actor_type`, `generation`
  (`20261109170000:13-20`).
- Staff/system cancellation constraints (`20261109170000:34-69`).
- Immutability for cancellation attribution once cancelled
  (`20261109180000:289-335`).

### 2.2 Database behavior

| Function / trigger | Behavior | Source |
| --- | --- | --- |
| `private.generate_kitchen_tickets(uuid, uuid)` | Resolves active item-level routing before category routing; reuses the active ticket or inserts `max(generation)+1`; idempotent item insert. | `20261109170000:532-717` |
| `private.cancel_kitchen_tickets_for_order(uuid, uuid, text)` | Cancels all non-cancelled ticket items then tickets; staff/system actor domains; skips completed-item guard via a transaction-local GUC. | `20261109170000:723-812` |
| `private.recalculate_kitchen_ticket_status(uuid)` | Locks ticket; derives aggregate from active items; leaves empty tickets unchanged; never reopens cancelled tickets. | `20261109170000:407-526` |
| `private.guard_kitchen_ticket_item_status()` | Enforces forward transitions; cancellation requires reason and actor; completed items cannot be cancelled except in whole-order cancellation. | `20261109170000:176-270` |
| `private.guard_kitchen_ticket_status()` | Rejects persisted aggregate mismatches, direct cancellation with active items, and non-cancelled status on empty tickets. | `20261109170000:272-401` |
| `private.kitchen_ticket_items_apply_aggregate()` | `AFTER INSERT OR UPDATE OF status`; locks parent ticket; recalculates for direct writes; rejects active items under cancelled tickets. | `20261109180000:217-283` |
| `private.guard_kitchen_cancellation_attribution_immutability()` | Rejects changes to cancellation actor/timestamp/reason once a row is cancelled. | `20261109180000:289-335` |
| `orders_generate_and_cancel_kitchen_tickets` | On order `accepted`, generate; on `cancelled`, propagate cancellation. | `20261109160000:731-733` |
| `order_items_generate_kitchen_tickets` | Routes items inserted into an already accepted order. | `20261109160000:761-763` |
| `order_items_cancel_kitchen_tickets` | Cancels matching ticket items and recalculates affected tickets. | `20261109160000:825-827` |
| Audit triggers | Ticket created, ticket status changed, ticket-item status changed. | `20261109160000:868-955` |

Routing precedence is implemented in `generate_kitchen_tickets`
(`20261109170000:567-616`): item-level routes are exclusive, category routes are
fallback, inactive stations are filtered, and unrouted items are skipped.

### 2.3 Authorization

Kitchen tables enable RLS and grant only `SELECT` to `authenticated`
(`20261109150000:220-249`). Policies use
`authz.has_branch_role(branch_id, array['owner','admin','manager','kitchen_staff'])`
(`:251-294`). Cashier is intentionally excluded.

`authz.has_branch_role` requires an active branch, an active staff profile, an
unrevoked role assignment, and either organization scope or a matching branch
assignment (`20261108100000:240-275`). `authz.has_branch_access`, used by
orders/items/tables/sessions RLS and M3 read RPCs, admits any active
branch-assigned staff role (`:196-238`).

### 2.4 Contracts, tests, documentation

- `src/contracts/kitchen/rpc.ts:8-71` defines ticket/item statuses and the ticket
  JSON shape returned by transition RPCs.
- `src/contracts/kitchen/rpc.ts:80-135` defines routing-issue contracts.
- **No read/list contracts** for kitchen tickets and **no station-management
  contracts** exist.
- `src/contracts/common/errors.ts:10-108` omits every `KITCHEN_*` error code
  raised by the migrations.
- Tests: `tests/integration/security/m4-kitchen-infrastructure.test.ts` (9
  tests) and `tests/integration/security/m4-kitchen-ticket-lifecycle.test.ts`
  (42 tests), plus `tests/contract/m4-contracts.test.ts` (6 tests).
- Docs: `docs/m4-kitchen-infrastructure.md`,
  `docs/m4-kitchen-ticket-lifecycle.md`, `docs/api-and-rpc-contracts.md`,
  `docs/data-model.md`, `docs/schema/database-foundation.md`.

### 2.5 Realtime

`supabase/config.toml:88-91` enables the local Realtime service, but no migration
adds any table to a Realtime publication and no migration sets replica identity.
`docs/test-blockers.md:16` registers `BLK-008`; `docs/backend-services.md:470,485`
confirms Realtime publication is not configured;
`docs/realtime-architecture.md:70-77` states the publication is intentionally not
enabled without an approved tenant/branch subscription design.

---

## 3. Existing RPC/API capability matrix

### 3.1 Kitchen RPCs

| RPC / signature | Purpose | Authentication and roles | Branch authorization | Station-level authorization | Repeat safety | KDS suitability |
| --- | --- | --- | --- | --- | --- | --- |
| `public.start_kitchen_ticket_item(p_ticket_item_id uuid)` (`20261109160000:1086-1098`) | `pending → preparing` on one ticket item; returns full ticket JSON. | `authz.require_staff_id()`; Owner/Admin/Manager/Kitchen Staff branch role (`:1019-1022`). Cashier denied. | Ticket branch via `assert_branch_role`; cross-organization returns `KITCHEN_TICKET_ITEM_NOT_FOUND`. | No station check; branch-wide. | Repeated same-target call is a no-op (`:1043-1046`). | Yes for item progress. |
| `public.mark_kitchen_ticket_item_ready(p_ticket_item_id uuid)` (`:1100-1112`) | `preparing → ready`. | Same as above. | Same. | Branch-wide. | Same-target no-op. | Yes. |
| `public.complete_kitchen_ticket_item(p_ticket_item_id uuid)` (`:1114-1126`) | `ready → completed`. | Same as above. | Same. | Branch-wide. | Same-target no-op. | Yes. |
| `private.transition_kitchen_ticket_item(uuid, kitchen_ticket_status)` (`:961-1084`) | Shared implementation; not client-executable. | Internal. | Item lock then ticket lock; organization and branch checks. | Branch-wide. | Idempotent for same target; rejects skipped/backward transitions. | Internal only. |
| `public.list_kitchen_routing_issues(p_branch_id uuid)` (`20261109170000:1104-1215`) | Read-only inactive routing diagnostics. | Owner/Admin/Manager only (`:1127-1130`). Cashier and Kitchen Staff denied. | `BRANCH_NOT_FOUND` outside organization; `PERMISSION_DENIED` without branch role. | Branch-wide. | Read-only. | Useful for setup diagnostics, not KDS runtime. |

Transition RPCs return the ticket JSON from `private.kitchen_ticket_json`
(`20261109170000:129-170`), which contains ticket identity, generation,
aggregate status, timestamps, cancellation actor fields, and items. Item JSON
(`:93-125`) contains `menuItemId`, `name`, `quantity`, `notes`, status,
timestamps, and cancellation fields. **It does not contain modifiers, station
name, order reference, table label, or order status.**

### 3.2 Adjacent read RPCs usable for order context

| RPC / signature | Purpose | Roles | Branch behavior | KDS suitability |
| --- | --- | --- | --- | --- |
| `public.get_order(p_order_id uuid)` (`20261108111100:329-364`) | Full order detail including items and modifiers. | Any active staff with branch history access. | Organization + branch checks; inactive branch history allowed for org-scoped staff. | Good for order detail, but no table label or ticket context. |
| `public.list_orders_by_session(uuid, order_status, int, int)` (`:366-442`) | Paginated order summaries for one session. | Any active staff with branch history access. | Session organization and branch checks. | Not ticket-oriented. |
| `public.list_branch_orders(uuid, order_status, timestamptz, timestamptz, int, int)` (`:444-527`) | Paginated branch order list. | Any active staff with branch history access. | Branch organization check; `assert_branch_history_access`. | Could power an order board, not a station KDS. |
| `public.get_table` / `list_branch_tables` (`20261108111000:11,60`) | Table reads. | Any active staff with branch history access. | Branch checks. | Needed for table label, but a separate round trip. |
| `public.get_dining_session` / `list_branch_dining_sessions` (`20261108111000:409,186`) | Session reads. | Any active staff with branch history access. | Branch checks. | Needed for table context, but a separate round trip. |

These RPCs use `private.order_summary_json` / `order_detail_json`
(`20261108110900:67-195`). Order summaries include order reference, status,
subtotal, notes, item counts, and lifecycle timestamps; item detail includes
modifier snapshots and item notes. **Neither includes table label or kitchen
station.**

### 3.3 Order-side write RPCs relevant to kitchen behavior

| RPC | Relevance | Current behavior |
| --- | --- | --- |
| `public.transition_order_status(p_order_id, p_status, p_reason)` (`20261108111100:916-1037`) | Kitchen staff can move the order `accepted → preparing → ready` (`:949-953`). | Cascades `order_items.status` (`:997-1016`) but does **not** update `kitchen_ticket_items.status`. M3 doc notes item-level independent transitions were deferred (`docs/m3-core-pos-operations.md:160-162,432-435`), but M4.2 now implements them separately. |
| `public.remove_order_item(p_order_item_id, p_reason)` (`20261109180000:67-211`) | Cancels an order item and matching ticket items. | Roles: Owner/Admin/Manager/Cashier (`:104-107`). Kitchen Staff denied. Allows orders in `pending`, `accepted`, `preparing`, `ready` when no matching ticket item is `completed`; terminal orders rejected (`:141-171`). Recalculates subtotal via a transaction-local guard exception (`:181-195`). |
| `public.cancel_order(...)` (`20261108111100:1039+`) | Cancels the order; the M4 order trigger cancels all tickets/items. | Owner/Admin/Manager/Cashier. Whole-order cancellation is the only path allowed to cancel completed kitchen work (`20261109170000:767-773`). |
| `public.add_order_item(...)` / `public.update_order_item_quantity(...)` | Order edits before preparation. | Existing M3 rules; quantity changes blocked after preparation (`20261108110800:80-96`). |

### 3.4 RPCs that do not exist

There is **no** public function in any migration that:

- lists or gets kitchen tickets for a branch/station;
- creates, updates, deactivates, or reactivates a kitchen station;
- sets or removes category/item routing;
- lets kitchen staff cancel an individual ticket item;
- acknowledges a ticket, changes priority, recalls/reopens an item or ticket, or
  transfers a ticket/station.

A search of all `create or replace function public.*` definitions
(`supabase/migrations/*.sql`) confirms the only kitchen-domain public functions
are the three transition RPCs and `list_kitchen_routing_issues`.

---

## 4. KDS read-model gap analysis

### 4.1 Capability matrix

| KDS need | Current support | Evidence / gap |
| --- | --- | --- |
| List active tickets for a branch | **Partial** — direct `SELECT` through RLS. | `kitchen_tickets_select_kitchen_roles` (`20261109150000:278-285`); index `(branch_id, status, created_at)` (`:169-170`). No read RPC and no contract; client must filter `status` and build its own response shape. |
| Filter tickets by station | **Partial** — direct `SELECT ... where station_id = ...`. | Index `(station_id, status, created_at)` (`:172-173`). No RPC; no station-scoped authorization. |
| Ticket details and ticket items | **Partial** — two direct `SELECT`s or PostgREST embedding. | `kitchen_ticket_items` RLS (`:287-294`); `(ticket_id)` and `(ticket_id, status)` indexes (`:211-212`, `20261109160000:47-48`). |
| Associated order context | **Partial** — join `orders` directly or call `get_order`. | `orders_select_branch` (`20261108100100:170-172`); `OrderSummary` has order reference/status/timestamps (`20261108110900:67-115`). |
| Table number/name | **Partial** — join `orders → dining_sessions → restaurant_tables.label`. | `restaurant_tables.label` (`20261108090500:7`); session table FK (`:49-70`). Not included in any ticket/order JSON. |
| Item names, quantities, notes | **Yes** — ticket item JSON includes name/quantity/notes. | `private.kitchen_ticket_item_json` (`20261109170000:93-125`). |
| Item modifiers | **No** in ticket JSON; **partial** via direct join or `get_order`. | `order_item_modifiers` (`20261108090600:176-197`); `order_item_json` includes modifiers (`20261108110900:144-160`); ticket item JSON does not. |
| Order age / elapsed preparation | **Partial** — timestamps are available; no computed field. | Ticket `created_at`, `started_at`, `ready_at`, `completed_at`; item timestamps; order `accepted_at`. Client can compute age, but the ticket `created_at` resets for a new generation, so order age should use `orders.accepted_at` or the earliest generation. |
| Sort by priority, age, creation | **Partial** — creation time only. | Indexes support `created_at`; there is no priority column or priority RPC. |
| Cancelled/completed history | **Partial** — direct `SELECT` with status filter. | RLS does not hide cancelled/completed tickets; no history RPC or retention contract. |
| Efficient pagination / bounded results | **No server-enforced bound.** | Direct `SELECT` relies on the client/PostgREST limit; there is no kitchen list RPC with a max page size. |

### 4.2 Are direct authenticated `SELECT`s sufficient?

**Technically they expose the necessary rows, but they are not sufficient as a
product contract.**

Direct `SELECT` can produce a KDS view through PostgREST resource embedding:

```text
kitchen_tickets
  → kitchen_ticket_items
    → order_items
      → order_item_modifiers
  → orders
    → dining_sessions
      → restaurant_tables
  → kitchen_stations
```

The composite foreign keys make these embeddings possible, and RLS is applied per
table. However:

- The response is raw snake_case database rows, not the camelCase contracts used
  by `src/contracts/kitchen/rpc.ts` and `src/contracts/order/rpc.ts`.
- There are no generated database types in the repository (the contract drift
  check reports no generated types), so the POS/KDS would need hand-maintained
  row types.
- The query shape is complex and easy to break; the frontend would encode
  relationship names and nested select syntax.
- Each embedding level is a separate backend query; a naive per-ticket fetch is
  an N+1 pattern.
- There is no single place to enforce a page-size cap, a station-scoped read
  policy, or a stable response contract.
- The transition RPCs return a different ticket shape than a direct table read,
  so the frontend would need two mapping layers.

**Recommendation:** add dedicated read RPCs with shared contracts:

- `public.list_kitchen_tickets(branch_id, station_id?, statuses?, limit, offset)`
  returning `{ branchId, tickets[], pageSize, hasMore, nextOffset }`.
- `public.get_kitchen_ticket(ticket_id)` returning the same ticket shape.

The response should include:

- ticket identity, `generation`, aggregate status, station id/name, timestamps;
- order id, order reference, order status, source, `accepted_at`, order notes;
- table id and label (from the active/associated dining session);
- items with `ticketItemId`, `orderItemId`, `menuItemId`, name, quantity, notes,
  kitchen status, item timestamps, cancellation fields, and modifier snapshots;
- `createdAt`/`updatedAt` for each object;
- a server-calculated `ageSeconds` or the raw timestamps (client can compute age).

Keep direct `SELECT` on `kitchen_stations` and route tables for configuration
reads if a dedicated station-list RPC is not implemented immediately.

---

## 5. Station access and authorization analysis

### 5.1 Current model

- Stations are branch-scoped (`kitchen_stations.branch_id`,
  `20261109150000:25-47`).
- Routing tables are branch-scoped and reference a station in the same branch and
  organization (`:64-114`).
- There is **no station-assignment table**, no `station_id` on
  `staff_role_assignments`, and no `station_id` on `staff_branch_assignments`.
  M2 role scope is `organization` or `branch`
  (`20261108120000_m2_branch_scoped_staff_roles.sql:146-159`).
- Kitchen RLS and RPC authorization use branch role only
  (`20261109150000:251-294`; `20261109160000:1019-1022`).

**Consequence:** every Kitchen Staff member assigned to a branch can read every
station's tickets in that branch and can transition every ticket in that branch.
Cross-branch access is denied; cross-station access is not denied.

### 5.2 Supported station-access patterns

| Pattern | Supported today? | Notes |
| --- | --- | --- |
| Kitchen staff assigned to one station | **No** | No station assignment model; branch-wide access only. |
| Kitchen staff assigned to multiple stations | **No explicit model** | They receive all stations in the branch. |
| Kitchen staff with access to all stations | **Yes** | Branch-wide RLS/RPC authorization. |
| Manager/owner access to all stations in a branch | **Yes** | Branch role covers the branch. |
| Cashier access to stations/tickets | **No** | Kitchen tables exclude cashier; order RPCs still allow cashier order operations. |

### 5.3 Station management

There are no station CRUD RPCs. M4.1 creates the tables and grants `SELECT` only
(`20261109150000:245-249`); authenticated `INSERT`/`UPDATE`/`DELETE` are denied.
The only way to create or configure a station today is a privileged database
write (migration/seed/service role), which is not a production application path.

This is a **delivery blocker for a production KDS**: an operator cannot create a
station, rename it, deactivate it, or configure category/item routing through the
POS.

Recommended M4.3 station-management surface:

- `create_kitchen_station(branch_id, name, description?)`
- `update_kitchen_station(station_id, name?, description?)`
- `deactivate_kitchen_station(station_id, reason?)`
- `reactivate_kitchen_station(station_id)`
- `set_kitchen_station_category_route(station_id, menu_category_id, active)` or
  explicit add/remove RPCs
- `set_kitchen_station_item_route(station_id, menu_item_id, active)` or explicit
  add/remove RPCs
- `list_kitchen_stations(branch_id)` (read)

Authorization should be Owner/Admin/Manager in the station branch. Kitchen Staff
should read configuration but not modify it. All writes should be audited using
the existing `private.audit_write` convention (`menu.*` RPCs already do this).
Unique-name and duplicate-route conflicts should be normalized to
`RESOURCE_CONFLICT` (or a new domain code) as the existing menu/staff RPCs do.

### 5.4 Deactivation semantics

Current behavior is correct for KDS operations:

- Inactive stations are skipped by generation (`20261109170000:587-591,604-608`).
- Existing tickets remain readable and completable; the transition RPC does not
  require an active station (`20261109160000:1019-1022`).
- Deactivation does not cancel existing tickets (no trigger; documented in
  `docs/m4-kitchen-ticket-lifecycle.md:223-232`).
- Reactivation restores existing routes.

Open product question: should a station be deactivatable while it has active
tickets? Current schema allows it; tickets remain operable. That is reasonable,
but M4.3 should document and test it explicitly.

---

## 6. Realtime readiness assessment

### 6.1 Current state

| Item | State |
| --- | --- |
| Realtime service enabled locally | `supabase/config.toml:88-91` (`enabled = true`). |
| Publication membership | **None.** No migration contains `alter publication supabase_realtime add table`. |
| Replica identity | **Default (primary key).** No `alter table ... replica identity` exists. |
| RLS compatibility | Policies exist and are branch-scoped, but Realtime delivery with RLS is **Not Verified** because no publication exists and no realtime test infrastructure has been run. |
| Client grants | `authenticated` has `SELECT`; `anon` has none. |
| Realtime client dependency | `@supabase/supabase-js` is already a dependency (`package.json:44-47`), so integration tests can use it when the local Supabase stack is running. |
| Approval status | `BLK-008` remains open (`docs/test-blockers.md:16`; `docs/backend-services.md:470,485`). |

### 6.2 Event observability

| Source | INSERT | UPDATE | DELETE | Notes |
| --- | --- | --- | --- | --- |
| `kitchen_tickets` | New ticket generation. | Aggregate status, timestamps, cancellation. | Not used (no client delete; FKs restrict). | Subscribe for ticket creation/aggregate changes. |
| `kitchen_ticket_items` | Item added to a ticket. | Item progress and cancellation. | Not used. | **Required** because ticket-level events do not fire for item changes that do not change the aggregate. |
| `kitchen_stations` | Station created. | Rename/deactivate/reactivate. | Not used. | Useful for configuration screens. |
| `kitchen_station_menu_items` / `_categories` | Route added. | — | Route removed. | Useful for configuration screens. |
| `orders` / `order_items` | Order created/items added. | Order status/quantity. | — | Not required for KDS item progress; order context can be fetched on demand. |

Important: `private.recalculate_kitchen_ticket_status` only updates
`kitchen_tickets` when the derived status changes
(`20261109170000:500-519`). If an item moves `pending → preparing` while the
ticket is already `preparing`, no ticket row update occurs. Therefore a
subscription to `kitchen_tickets` alone is **not sufficient**.

### 6.3 Recommended subscription model

Use one channel per authorized branch (optionally per station):

```text
channel: kds:branch:<branchId>
filters:
  kitchen_tickets:       branch_id = eq.<branchId>
                         (optional) station_id = eq.<stationId>
  kitchen_ticket_items:  branch_id = eq.<branchId>
  kitchen_stations:      branch_id = eq.<branchId>
  kitchen_station_menu_items:      branch_id = eq.<branchId>
  kitchen_station_menu_categories: branch_id = eq.<branchId>
```

Notes:

- `kitchen_tickets` and `kitchen_ticket_items` both carry `branch_id`, so a
  branch filter is possible. `kitchen_ticket_items` does **not** carry
  `station_id`; station-specific item filtering requires client-side mapping via
  `ticket_id`, per-ticket subscriptions, or a future denormalized `station_id`.
  For initial KDS volume, a branch-level item subscription with client-side
  station mapping is the simplest safe option.
- Use `replica identity full` on `kitchen_tickets` and
  `kitchen_ticket_items` if DELETE events or old-row filtering are needed. Kitchen
  tables are never deleted by normal flows, so this can be deferred, but document
  the limitation.
- Do not subscribe to `orders` or `order_items` for KDS item progress; that would
  increase volume and duplicate the kitchen state.

### 6.4 Frontend behavior after an event

- Treat every event as a **notification**, not as the authoritative payload.
- On ticket INSERT/UPDATE: refetch the affected ticket (or the active list) through
  the read RPC.
- On ticket-item INSERT/UPDATE: refetch the parent ticket.
- On station/route events: refetch station configuration.
- Debounce bursts (e.g., one refetch per ticket per ~250–500 ms).
- Ignore events for tickets not in the current branch/station view.

### 6.5 Recovery and polling

Realtime delivery is not guaranteed. The KDS should:

1. Load the authoritative active-ticket list through the read RPC on mount.
2. Subscribe after the initial load.
3. On reconnect, subscription error, or `visibilitychange`, refetch the full list
   (or a bounded "updated since" query).
4. Run a polling fallback every 30–60 seconds while the screen is visible.
5. Reconcile by ticket id; handle duplicate, delayed, and out-of-order events.

There is no server-side event cursor or sequence number today. A bounded refetch
by `updated_at`/`created_at` is the practical recovery mechanism; the read RPC
should return `updatedAt` on tickets and items.

### 6.6 Realtime security requirements

Before enabling the publication:

- Verify that Realtime Postgres Changes applies the existing `SELECT` RLS policies
  for `authenticated` subscribers.
- Verify that `anon` receives no events.
- Verify that a Kitchen Staff user in branch A receives no rows from branch B or
  another organization.
- Verify that Cashier receives no kitchen events.
- Verify that station configuration events are branch-scoped.
- Document the exact channel naming, filters, payload fields, and recovery
  behavior in the Realtime contract.

If these tests cannot be run (no Docker/local Supabase), do **not** claim Realtime
security is verified. Keep `BLK-008` open and use polling until verified.

---

## 7. Security findings

### 7.1 Summary

No client-reachable critical or high-severity authorization defect was found in
the inspected source. The kitchen write model is RPC-only, the read model is
branch-scoped, and the known privileged-write findings from the M4.2 review do not
materially affect KDS capability or create a client-reachable issue. They are not
reopened here.

### 7.2 Findings register

| ID | Type | Severity | Finding | Evidence | Why it matters | Recommendation |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-1 | Security / future risk | **Medium** | Realtime publication is absent; enabling it without RLS verification could expose branch tickets across tenants. | No publication in any migration; `BLK-008` (`docs/test-blockers.md:16`); `docs/realtime-architecture.md:70-77`. | Realtime bypasses the normal request path; RLS behavior must be proven, not assumed. | Implement Realtime only with branch-scoped filters and two-tenant RLS tests. Keep polling fallback. |
| SEC-2 | Least privilege | **Low** | Kitchen Staff can read all branch orders, order totals, staff cancellation ids, and all stations in the branch. | `orders_select_branch` uses `authz.has_branch_access` (`20261108100100:166-172`); `get_order`/`list_branch_orders` allow any branch staff (`20261108111100:329-364,444-527`); kitchen RLS is branch-wide (`20261109150000:251-294`). | Kitchen staff may not need financial totals or other stations' tickets. This is a product/least-privilege decision, not a bypass. | Decide whether to add a KDS-specific read shape that omits financial fields and/or station-level access. Do not add station-level authorization without a product decision. |
| SEC-3 | Operational visibility | **Low** | Kitchen ticket history becomes unreadable after a branch is deactivated. | Kitchen RLS uses `authz.has_branch_role`, which requires `branches.status = 'active'` (`20261108100000:240-275`); M3 order reads use `private.assert_branch_history_access` to allow inactive-branch history (`20261108110900:17-63`). | Historical KDS tickets may be needed for audit/incident review. | Decide whether kitchen history should support inactive branches; if so, add a read-only history policy consistent with M3. |
| SEC-4 | Design boundary | **Low** | No station-level access control; every branch kitchen user sees every station. | No station assignment table; RLS/RPC use branch role only (`20261109150000:251-294`; `20261109160000:1019-1022`). | Not a vulnerability: the user is authorized for the branch. It is a product requirement gap if stations must be isolated. | Treat branch-wide access as the v1 model unless product requires station assignment. |
| GAP-1 | Delivery blocker | **High** | No KDS read RPC/contract. | Only direct table `SELECT`; no `list_kitchen_tickets`/`get_kitchen_ticket`; ticket JSON lacks table/modifiers/order context. | The KDS would encode raw DB shapes and N+1 queries. | Add read RPCs and contracts (M4.3 T1/T2). |
| GAP-2 | Delivery blocker | **High** | No station/routing management RPCs. | No public function references `kitchen_stations`; only table creation/RLS/grants (`20261109150000:25-315`). | Operators cannot configure a production KDS through the app. | Add station/routing RPCs (M4.3 T3). |
| GAP-3 | Contract gap | **Medium** | Kitchen SQL error codes are not in `API_ERROR_CODES`. | `src/contracts/common/errors.ts:10-108`; codes raised in `20261109160000`/`20261109170000`/`20261109180000`; no contract test references them. | The POS cannot type/map kitchen errors with the shared error union; UI error handling becomes ad hoc. | Add `KITCHEN_*` codes and contract tests (M4.3 T1). |
| GAP-4 | Product/capability gap | **Medium** | No ticket priority, acknowledgement, recall/reopen, station transfer, or kitchen-side item cancellation. | No columns/RPCs; backward transitions rejected by `guard_kitchen_ticket_item_status` (`20261109170000:244-253`); item cancellation only via order roles (`20261109180000:104-107`). | Some are expected KDS features; others may be deferred. | Decide per item; implement only approved ones (M4.3 T6 / defer). |
| GAP-5 | Architecture/product | **Medium** | Order status and kitchen state are independent and can diverge. | `transition_order_status` cascades order items only (`20261108111100:997-1016`); kitchen RPCs never update orders (`docs/m4-kitchen-ticket-lifecycle.md:324-325`). | The POS order board and KDS can show conflicting states. | Decide which state each UI uses; document; optionally restrict kitchen staff from order-level transitions (M4.3 T5). |
| GAP-6 | Delivery blocker | **High** | Realtime is not implemented or approved. | No publication/replica identity; `BLK-008`. | KDS would rely on polling only. | Implement publication + contract + RLS tests (M4.3 T4). |
| GAP-7 | Documentation | **Low** | `BLK-002` still says item-level preparation transitions are deferred, contradicting M4.2. | `docs/test-blockers.md:9`; `docs/backend-services.md:464`; M4.2 implements item transitions (`20261109160000:961-1126`). | Confusing planning/traceability; may cause duplicate work or skipped tests. | Split/update `BLK-002` so only the still-blocked billing/KDS-notification parts remain (M4.3 T7). |
| GAP-8 | Operational | **Medium** | No server-enforced page bound for a KDS list. | No kitchen list RPC; direct `SELECT` has no max page cap. | A client bug could request all historical tickets. | Read RPC with `limit <= 100` and `hasMore` (M4.3 T2). |
| GAP-9 | Realtime detail | **Low** | `kitchen_ticket_items` has no `station_id`, so station-filtered item subscriptions are not direct. | `kitchen_ticket_items` columns (`20261109150000:191-209`; `20261109160000:23-31`). | Station-specific KDS must map `ticket_id` → station client-side or subscribe per ticket. | Start with branch-level item subscription; add `station_id` later only if volume requires. |

### 7.3 Mental authorization tests

| Actor / attempt | Expected and observed design |
| --- | --- |
| Anonymous `SELECT` kitchen tables | Denied by missing grants; tested in `m4-kitchen-infrastructure.test.ts:986-989` (`permission denied`). |
| Authenticated non-staff | `has_branch_role` false → zero rows; transition RPC raises `STAFF_NOT_ACTIVE` via `authz.require_staff_id` (`20261108100000:387-409`). |
| Cashier `SELECT` kitchen tables | Zero rows; policies exclude cashier (`20261109150000:251-294`); tested `m4-kitchen-infrastructure.test.ts:942-973`. |
| Cashier transition RPC | `PERMISSION_DENIED`; tested `m4-kitchen-ticket-lifecycle.test.ts:1149-1152`. |
| Kitchen Staff transition own branch | Allowed; tested `:1193-1196`. |
| Kitchen Staff cross-branch ticket | `PERMISSION_DENIED`; tested `:1154-1160`. |
| Cross-organization ticket | `KITCHEN_TICKET_ITEM_NOT_FOUND`; tested `:1162-1169`. |
| Direct `INSERT`/`UPDATE`/`DELETE` kitchen tables | `permission denied`; tested `m4-kitchen-infrastructure.test.ts:991-1013` and `m4-kitchen-ticket-lifecycle.test.ts:1199-1227`. |
| Mismatched ticket/item relationships | Not expressible through the transition RPC (only the item id is accepted); composite FKs enforce ticket/order/branch/organization consistency (`20261109150000:201-208`). |
| Cross-station access | Allowed within the branch by design; no station assignment model. |

No client-reachable gap was found in these paths.

---

## 8. Performance and operational considerations

### 8.1 Existing indexes relevant to KDS reads

| Table | Index | KDS use |
| --- | --- | --- |
| `kitchen_tickets` | `(branch_id, status, created_at)` (`20261109150000:169-170`) | Branch active list filtered by status. |
| `kitchen_tickets` | `(station_id, status, created_at)` (`:172-173`) | Station board. |
| `kitchen_tickets` | `(order_id)` (`:175-176`) | Ticket lookup by order. |
| `kitchen_tickets` | `(order_id, station_id, generation)` unique (`20261109170000:32-33`) | Generation idempotency. |
| `kitchen_tickets` | Partial unique `(order_id, station_id) where status <> 'cancelled'` (`:73-75`) | One active ticket lookup. |
| `kitchen_ticket_items` | `(ticket_id)` (`20261109150000:211-212`) | Ticket detail items. |
| `kitchen_ticket_items` | `(ticket_id, status)` (`20261109160000:47-48`) | Item aggregation and filtering. |
| `kitchen_ticket_items` | `(order_item_id)` (`20261109150000:214-215`) | Cancellation lookup. |
| `orders` | `(branch_id, status, created_at)` (`20261108090600:101-102`) | Order context and history. |
| `order_items` | `(order_id)` and `(branch_id, status)` (`:166-170`) | Item context. |
| `order_item_modifiers` | `(order_item_id)` (`:196-197`) | Modifier snapshots. |
| `restaurant_tables` | `(branch_id, status)` (`20261108090500:24-25`) | Table lookup. |
| `dining_sessions` | `(branch_id, status, opened_at desc)` (`:85-86`) | Active session lookup. |

No index on `kitchen_tickets (branch_id, created_at)` exists for an unfiltered
history list across all statuses. If history is a required KDS view, measure the
query and add a targeted index rather than speculating.

### 8.2 Query pattern and N+1 risk

The natural KDS list needs, per ticket:

- ticket row;
- station row;
- order row;
- dining session and table row;
- ticket items;
- order items (name/quantity/notes);
- modifier rows.

A per-ticket loop produces N+1 queries. A single read RPC using `jsonb_agg`
subqueries (similar to `private.kitchen_ticket_json`) or a single PostgREST
embedding avoids that. The read RPC should aggregate items and modifiers in one
statement and cap the page size.

### 8.3 Volume and event rate

No runtime volume data was collected in this read-only assessment. Measure before
choosing limits:

- tickets per branch per hour;
- items per ticket;
- stations per branch;
- item transitions per ticket (up to 3 state changes + cancellation);
- audit rows per transition (audit triggers add a row per status change).

A branch with many orders and many items will produce several Realtime events per
item. Debounce and refetch per ticket rather than per event. Do not subscribe to
`orders`/`order_items` unless a product requirement justifies the extra volume.

### 8.4 Pagination and retention

- Read RPC should enforce `limit <= 100` and return `pageSize`, `hasMore`, and
  `nextOffset`, matching M3 read RPC conventions
  (`20261108111100:399-440,478-525`).
- History queries should require a bounded `from`/`to` window.
- Completed/cancelled tickets accumulate; define a retention/archive policy before
  the KDS exposes unrestricted history.

### 8.5 Stale state and invalid transitions

- The database guards reject skipped, backward, and terminal transitions
  (`20261109170000:192-263`).
- Repeated same-target calls are safe no-ops (`20261109160000:1043-1046`).
- A stale KDS action therefore receives `KITCHEN_INVALID_TRANSITION`,
  `KITCHEN_TICKET_CANCELLED`, or `ORDER_MODIFICATION_NOT_ALLOWED`, and the client
  must refetch.
- There is no optimistic-concurrency version column; `updated_at` plus refetch is
  the practical reconciliation mechanism.
- Completion-vs-removal is serialized by row locks; tested with separate sessions
  (`m4-kitchen-ticket-lifecycle.test.ts:2905+`).

---

## 9. M4.3 implementation scope

The following tasks are independently testable. Each should be a separate
migration/contract/test increment.

### T1 — Shared kitchen contracts and error codes

**Scope**

- Add `KITCHEN_*` error codes to `src/contracts/common/errors.ts`:
  `KITCHEN_TICKET_ITEM_NOT_FOUND`, `KITCHEN_INVALID_TRANSITION`,
  `KITCHEN_TICKET_CANCELLED`, `KITCHEN_TICKET_INCONSISTENT`,
  `KITCHEN_CANCELLATION_INVALID`, and any station codes introduced by T3.
- Add request/response schemas for the three transition RPCs.
- Add contracts for KDS list/detail, station management, and Realtime event
  envelopes.
- Extend `src/index.ts` exports and contract tests.

**Acceptance criteria**

- All committed SQL error codes used by kitchen RPCs are representable in
  `API_ERROR_CODES`.
- Contract tests accept valid payloads and reject unknown/extra fields.
- No runtime SQL change in this task.

### T2 — KDS read RPCs

**Scope**

- `public.list_kitchen_tickets(p_branch_id uuid, p_station_id uuid default null,
  p_statuses public.kitchen_ticket_status[] default null, p_limit integer default
  50, p_offset integer default 0) returns jsonb`
- `public.get_kitchen_ticket(p_ticket_id uuid) returns jsonb`
- Optionally `public.list_kitchen_stations(p_branch_id uuid) returns jsonb`.

**Behavior**

- Authorization: Owner/Admin/Manager/Kitchen Staff in the branch; Cashier denied.
- Branch/organization checks before returning data.
- Station filter optional; all stations in the branch when omitted.
- Default statuses should be active work (`pending`, `preparing`, `ready`);
  history statuses must be explicitly requested.
- Include ticket, station name, order reference/status/source/accepted_at, table
  label, items, modifiers, notes, timestamps, cancellation attribution, and
  `generation`.
- Order by `created_at` ascending (oldest first) for the active board; support an
  explicit `created_at desc` for history if needed.
- Enforce `limit` 1–100 and return `hasMore`/`nextOffset`.
- Include `updatedAt` on tickets/items for reconciliation.
- Never return another branch's rows; cross-organization returns the existing
  domain error convention.

**Acceptance criteria**

- One round trip returns a complete station board without N+1 queries.
- Kitchen Staff sees all stations in the branch; Cashier is denied.
- Cross-branch and cross-organization reads are denied.
- Pagination is bounded and deterministic.
- Items include modifiers and notes.
- Tests cover empty boards, unrouted orders, cancelled/completed history,
  inactive stations, and multi-station orders.

### T3 — Station and routing management RPCs

**Scope**

- Create/update/deactivate/reactivate station RPCs.
- Add/remove category route RPCs.
- Add/remove item route RPCs.
- `list_kitchen_stations` read (or documented direct `SELECT` with contract).

**Behavior**

- Authorization: Owner/Admin/Manager in the branch; Kitchen Staff read-only.
- Enforce organization/branch consistency; reject cross-tenant references.
- Normalize duplicate name/route conflicts to `RESOURCE_CONFLICT` or a documented
  kitchen-specific code.
- Deactivation sets `status = 'inactive'` and `deactivated_at`; reactivation
  clears it.
- Do not delete stations with tickets; deactivate instead.
- Preserve item-level precedence and inactive-station behavior.
- Audit every write using the existing audit convention.
- Do not allow creating routes to an inactive station unless product explicitly
  approves it; editing/removing existing routes should remain possible.

**Acceptance criteria**

- A branch can be fully configured through RPCs.
- Cashier/Kitchen Staff cannot mutate configuration.
- Duplicate names/routes are rejected deterministically.
- Deactivation stops new routing but leaves existing tickets readable and
  completable.
- Cross-branch/cross-organization attempts fail.
- Audit rows are written.

### T4 — Realtime publication and subscription contract

**Scope**

- Add the approved tables to the `supabase_realtime` publication.
- Set replica identity where required.
- Define channel names, filters, payload fields, and recovery behavior in
  `docs/realtime-architecture.md` and the shared contracts.
- Add RLS/Realtime integration tests using `@supabase/supabase-js` against the
  local Supabase stack.

**Recommended publication**

- `kitchen_tickets`
- `kitchen_ticket_items`
- `kitchen_stations`
- `kitchen_station_menu_items`
- `kitchen_station_menu_categories`

**Acceptance criteria**

- Branch A Kitchen Staff receives events for branch A only.
- Branch B and Cashier receive none.
- Anonymous receives none.
- Ticket INSERT/UPDATE and item INSERT/UPDATE are delivered.
- Station configuration changes are delivered.
- Reconnect + full refetch produces the correct persisted state.
- If Docker/local Supabase is unavailable, the task is **not complete**; do not
  claim verification.

### T5 — Order-state versus kitchen-state policy

**Scope (decision + documentation; narrow code only if approved)**

- Decide whether the KDS is driven exclusively by kitchen ticket/item state.
- Decide whether Kitchen Staff should retain `transition_order_status` access for
  `preparing`/`ready` while using the KDS.
- Document the chosen policy in `docs/m3-core-pos-operations.md`,
  `docs/m4-kitchen-ticket-lifecycle.md`, and `docs/api-and-rpc-contracts.md`.
- If approved, add a guard or role restriction to prevent conflicting controls.

**Acceptance criteria**

- The POS/KDS state ownership is unambiguous.
- No existing M3 behavior changes without an explicit decision.
- Tests cover the chosen policy where behavior is changed.

### T6 — Approved ticket conveniences (optional for v1)

Candidate items, each requiring a product decision:

- Kitchen-side `cancel_kitchen_ticket_item(item_id, reason)`.
- Bulk `mark_ticket_ready(ticket_id)` / `complete_ticket(ticket_id)`.
- Ticket priority/expedite.
- Recall/reopen.
- Station transfer.

**Recommendation:** defer all of these unless the M4.4 UX explicitly requires
them. The existing item RPCs and order-side cancellation are sufficient for a
first KDS.

### T7 — Documentation and blocker-register hygiene

- Update `docs/m4-kitchen-ticket-lifecycle.md`, `docs/api-and-rpc-contracts.md`,
  `docs/data-model.md`, `docs/schema/database-foundation.md`, and
  `docs/backend-services.md`.
- Split/update `BLK-002` so it no longer claims item-level transitions are
  unimplemented; keep only the still-unapproved KDS notification/billing effects.
- Keep `BLK-008` open until Realtime is approved and verified.

### T8 — Validation and CI

- Run the full existing integration suite plus new M4.3 tests.
- Run static checks, typecheck, contract tests, migration governance, secret scan,
  blocker register, RLS manifest, and diff checks.
- Run Realtime tests when the local Supabase stack is available; otherwise mark
  them blocked, not passed.
- Validate a clean-database migration application.

### Explicit M4.3 non-goals

- No KDS frontend in this repository.
- No station-level staff assignment unless product approves it.
- No printer/KOT hardware integration.
- No offline mode.
- No payment changes.
- No guest-ordering UI.
- No retroactive rerouting of existing tickets.

---

## 10. M4.4 frontend dependencies

Before KDS frontend work starts, M4.3 must provide:

1. Typed, exported contracts for ticket list/detail, station list, and mutations.
2. A stable ticket response that includes station name, table label, order
   reference/status, item modifiers, notes, and timestamps.
3. Kitchen error codes in the shared error union with documented recovery
   behavior.
4. Station configuration RPCs so a test branch can be set up end-to-end.
5. A Realtime channel/filter/payload contract and a documented polling fallback.
6. A clear policy for order state vs kitchen state so the frontend does not mix
   them.
7. Bounded pagination and a defined history window.
8. Documented authorization behavior: Cashier denied; Kitchen Staff branch-wide;
   cross-branch denied.
9. A test recipe for two branches and two organizations so the frontend can
   validate isolation.

The frontend can start with polling after T1/T2/T3. Realtime-dependent UX should
wait for T4.

---

## 11. Deferred features and explicit non-goals

| Feature | Recommendation | Rationale |
| --- | --- | --- |
| Station-specific staff assignment | Defer unless product requires it | No assignment model exists; branch-wide access is the current approved model. |
| Ticket priority / expedite | Defer | No column or RPC; product must define priority semantics and sorting. |
| Ticket acknowledgement | Defer | Starting the first item is the current acknowledgement signal. |
| Recall / reopen completed work | Defer | Item/ticket guards make completed/cancelled terminal by design. |
| Station transfer | Defer | Ticket identity is `(order, station, generation)`; transfer needs new semantics. |
| Kitchen-side item cancellation | Defer (product decision) | Current cancellation is order-side (`remove_order_item`, `cancel_order`) with cashier/manager roles. |
| Bulk ticket ready/complete | Defer | Per-item RPCs are sufficient for v1; bulk can be added later. |
| Printers / KOT hardware | Defer | Not part of the backend data model. |
| Offline KDS | Defer | Realtime and local persistence design not approved. |
| Cross-branch aggregate KDS | Defer | Conflicts with branch-scoped authorization. |
| Guest-facing kitchen notifications | Defer | Guest ordering integration is out of scope. |
| Per-route quantity split | Defer | Current multi-station routing duplicates the item on each station. |
| Retroactive rerouting after route changes | Defer | Documented limitation; existing tickets are not rerouted. |
| Analytics / preparation-time reporting | Defer | Timestamps exist, but reporting contract is not defined. |
| Payment / billing changes | Out of scope | M4.3 is kitchen capability only. |

---

## 12. Recommended implementation order

1. **Product decisions (before code):** station access model, priority/ack,
   kitchen-side item cancellation, order-vs-kitchen state ownership, Realtime
   approval (`BLK-008`).
2. **T1 — Contracts and error codes.** Unblocks all client work and prevents
   ad-hoc shapes.
3. **T3 — Station/routing management.** Without it, a production branch cannot be
   configured through the app.
4. **T2 — KDS read RPCs.** Unblocks the frontend's initial load and polling mode.
5. **T4 — Realtime publication and contract.** Adds live updates after the read
   model is stable.
6. **T5 — Order/kitchen state policy.** Aligns POS and KDS controls; can be done
   in parallel with T2/T4 if the decision is available.
7. **T6 — Approved conveniences only.** Keep v1 small.
8. **T7/T8 — Documentation and validation.** Run before declaring M4.3 complete.

Rationale: station configuration is a prerequisite for meaningful end-to-end
tests; the read RPC is a prerequisite for the frontend; Realtime is additive and
security-sensitive, so it should follow a stable read model.

---

## 13. Test plan and acceptance criteria

### 13.1 Test layers

| Layer | Scope |
| --- | --- |
| Contract tests | New kitchen request/response schemas, error codes, Realtime envelope schemas. |
| Database integration / RLS | Real PostgreSQL sessions for every role, cross-branch, cross-organization, direct table reads/writes. |
| RPC behavior | List/detail filtering, pagination, ordering, history, empty boards, multi-station tickets, inactive stations. |
| Station management | Create/update/deactivate/reactivate, routes, duplicates, audit, inactive station behavior. |
| Realtime | Publication membership, replica identity, RLS delivery, reconnect/resync. Requires local Supabase/Docker. |
| Performance | `EXPLAIN (ANALYZE, BUFFERS)` on seeded realistic volume; no invented benchmarks. |
| Regression | Existing M4.1/M4.2/M3 suites and full integration suite. |

### 13.2 Required authorization matrix

For each new read/management RPC, test:

| Actor | Expected |
| --- | --- |
| Anonymous | No access (`permission denied` or `AUTH_REQUIRED`). |
| Authenticated non-staff | `STAFF_NOT_ACTIVE` or zero rows. |
| Cashier | Kitchen RPCs denied; order RPCs unchanged. |
| Kitchen Staff (branch A) | Branch A kitchen reads/transitions allowed; branch B denied. |
| Manager (branch A) | Allowed in branch A; branch B denied unless assigned. |
| Owner/Admin (organization scope) | All branches in the organization; other organization denied. |
| Cross-organization ticket/station id | Not found / no data; no existence leak. |
| Direct `INSERT`/`UPDATE`/`DELETE` | Denied for all client roles. |

### 13.3 Acceptance criteria for M4.3 completion

- T1–T4 are implemented and tested.
- No client-reachable authorization regression.
- Realtime RLS is either verified with two-tenant tests or explicitly remains
  blocked with polling fallback; it is not claimed as verified without tests.
- Kitchen error codes are part of the shared contract.
- A branch can be configured and operated end-to-end through RPCs.
- A KDS can load a station board in one bounded request and follow it with
  Realtime or polling.
- Documentation matches actual SQL and tests.
- Full regression suite passes on a clean disposable database.
- `BLK-008` and `BLK-002` accurately reflect what remains unapproved.

---

## 14. Open questions requiring product decisions

1. **Station access:** Should Kitchen Staff see all stations in a branch (current
   behavior), or must they be assigned to one or more stations? If assignments are
   required, M4.3 needs a new assignment table and RLS/RPC changes; otherwise
   branch-wide remains the v1 model.
2. **Ticket priority:** Does the first KDS need expedite/priority, or is
   oldest-first sufficient? Priority requires a column, mutation RPC, sorting
   rules, and audit.
3. **Acknowledgement:** Is "start first item" sufficient, or does the KDS need an
   explicit ticket acknowledgement state/timestamp?
4. **Kitchen-side item cancellation:** May Kitchen Staff cancel an individual
   ticket item? If yes, define how it interacts with `order_items.status` and
   order completion.
5. **Recall/reopen:** Is there an operational need to move a completed/ready item
   backward? Current guards forbid it.
6. **Station transfer:** Can an item/ticket move between stations after
   generation? Current ticket identity does not support it.
7. **Order vs kitchen state ownership:** Which UI owns `preparing`/`ready` — the
   POS order board, the KDS, or both? Should Kitchen Staff keep
   `transition_order_status` access?
8. **Financial visibility:** Should Kitchen Staff see order subtotals and
   cancellation actor ids, or only operational item data?
9. **Branch deactivation history:** Should kitchen tickets remain readable after
   a branch is deactivated for audit?
10. **History retention:** How long should completed/cancelled tickets remain
    queryable in the KDS, and what is the archive policy?
11. **Realtime approval (`BLK-008`):** Approve the proposed publication tables,
    channel naming, filters, and payload contract. Without approval, M4.4 must use
    polling.
12. **Polling cadence:** What refresh interval is acceptable when Realtime is
    disconnected? 30–60 seconds is a reasonable starting point, subject to
    measurement.
13. **Multi-station quantity semantics:** When one order item routes to multiple
    stations, should each station show the full quantity (current behavior) or a
    split quantity? A split is not represented today.
14. **Table display:** `restaurant_tables.label` is free text. Is that the value
    the KDS should display as the table number/name?
15. **Unrouted items:** Should the KDS surface unrouted items/orders as an
    operational warning, or remain ticket-only? Current generation silently skips
    them (documented).

---

## Appendix A — Files inspected

Migrations:

- `supabase/migrations/20261108090000_bootstrap.sql`
- `supabase/migrations/20261108090300_identity_and_access.sql`
- `supabase/migrations/20261108090400_menu_and_charges.sql`
- `supabase/migrations/20261108090500_tables_sessions_and_tokens.sql`
- `supabase/migrations/20261108090600_orders.sql`
- `supabase/migrations/20261108091000_integrity_guards_and_indexes.sql`
- `supabase/migrations/20261108100000_authz_helpers.sql`
- `supabase/migrations/20261108100100_rls_policies.sql`
- `supabase/migrations/20261108110700_m3_order_schema_extensions.sql`
- `supabase/migrations/20261108110800_m3_order_state_guards.sql`
- `supabase/migrations/20261108110900_m3_pos_read_helpers.sql`
- `supabase/migrations/20261108111000_m3_table_session_rpcs.sql`
- `supabase/migrations/20261108111100_m3_order_rpcs.sql`
- `supabase/migrations/20261108120000_m2_branch_scoped_staff_roles.sql`
- `supabase/migrations/20261109130000_m2_staff_rpc_concurrency_and_errors.sql`
- `supabase/migrations/20261109150000_m4_kitchen_infrastructure.sql`
- `supabase/migrations/20261109160000_m4_kitchen_ticket_lifecycle.sql`
- `supabase/migrations/20261109170000_m4_kitchen_ticket_lifecycle_corrections.sql`
- `supabase/migrations/20261109180000_m4_kitchen_ticket_lifecycle_final_corrections.sql`

Contracts and source:

- `src/contracts/kitchen/rpc.ts`
- `src/contracts/order/rpc.ts`
- `src/contracts/common/errors.ts`
- `src/index.ts`

Tests:

- `tests/integration/security/m4-kitchen-infrastructure.test.ts`
- `tests/integration/security/m4-kitchen-ticket-lifecycle.test.ts`
- `tests/integration/security/helpers.ts`
- `tests/contract/m4-contracts.test.ts`
- `tests/registry/rls-coverage.json`
- `supabase/tests/database/000_harness_smoke.test.sql`
- `supabase/tests/database/010_staff_branch_roles.test.sql`

Documentation and configuration:

- `docs/m4-kitchen-infrastructure.md`
- `docs/m4-kitchen-ticket-lifecycle.md`
- `docs/api-and-rpc-contracts.md`
- `docs/data-model.md`
- `docs/schema/database-foundation.md`
- `docs/backend-services.md`
- `docs/realtime-architecture.md`
- `docs/m3-core-pos-operations.md`
- `docs/test-blockers.md`
- `docs/implementation-roadmap.md`
- `docs/row-level-security.md`
- `docs/security-guidelines.md`
- `docs/system-overview.md`
- `supabase/config.toml`
- `package.json`

Git metadata:

- `git branch --show-current`
- `git rev-parse HEAD`
- `git status --short`
- `git log -1 a1a4e5e`

---

## Appendix B — Repository safety confirmation

- **No SQL migration was modified, added, or deleted.**
- **No application source or contract was modified.**
- **No test was modified.**
- **No existing documentation was modified.** The only file created is this
  assessment report.
- **No migration was applied.**
- **No database was started, reset, or modified.**
- **No Docker or local database configuration was changed.**
- **No hosted Supabase, Development, or Production project was accessed.**
- **No `.env`, `.env.local`, `.env.*`, credential, or secret-bearing
  configuration value was read, printed, or copied.**
- **No commit, push, merge, rebase, or deployment was performed.**
- **No branch switch or worktree creation occurred.**
- **HEAD remains `a1a4e5edc994b45d1066b28454a6149dba784b34` (`a1a4e5e`).**

The preflight checks passed before this report was created:

- Current directory is the specified M4 worktree.
- Branch is `feature/m4-1-kitchen-infrastructure`.
- HEAD is `a1a4e5e` / `a1a4e5edc994b45d1066b28454a6149dba784b34`.
- Working tree was clean at the start of the assessment.
