# M4.1 — Kitchen Infrastructure

M4.1 adds the database and authorization foundation for the Kitchen Display
System (KDS). It intentionally does **not** generate tickets, implement ticket
lifecycle RPCs, add realtime subscriptions, or change order lifecycle behavior.

M4.2 builds on this foundation with ticket generation, independent item
preparation state, ticket aggregation, cancellation propagation, and lifecycle
RPCs. See [`m4-kitchen-ticket-lifecycle.md`](./m4-kitchen-ticket-lifecycle.md).

## 1. Schema

| Table | Purpose |
| --- | --- |
| `public.kitchen_stations` | Branch-scoped kitchen stations with active/inactive state. |
| `public.kitchen_station_menu_categories` | Category-level menu routing to a station in a branch. |
| `public.kitchen_station_menu_items` | Item-level menu routing to a station in a branch. |
| `public.kitchen_tickets` | One active ticket per `(order, station)`, with cancelled generations retained as history. |
| `public.kitchen_ticket_items` | Immutable links from a ticket to `order_items`. |

All five tables have RLS enabled. Authenticated clients receive `SELECT` only
where a policy allows it; there are no authenticated `INSERT`, `UPDATE`, or
`DELETE` grants. Ticket generation and lifecycle changes remain backend/RPC-only.

## 2. Station rules

- A station belongs to exactly one organization and branch.
- `(branch_id, organization_id)` must reference an existing branch.
- Station names are unique per branch using a case-insensitive, trimmed
  comparison (`lower(btrim(name))`). The same name may exist in another branch.
- `status = 'inactive'` requires `deactivated_at`; `status = 'active'` requires
  `deactivated_at IS NULL`.
- Inactive stations keep their configuration and historical tickets. They are
  excluded from future automatic routing; they are not deleted.

## 3. Menu routing

Two explicit route tables are used, mirroring the existing
`branch_menu_categories` / `branch_menu_items` pattern:

- Category route: `menu_category_id` → station in a branch.
- Item route: `menu_item_id` → station in a branch.

A route is branch-scoped because the station is branch-scoped. The menu target
must belong to the same organization. There is no requirement for a
`branch_menu_items` or `branch_menu_categories` row because menu availability
defaults are intentionally not encoded as row presence.

### Routing precedence (M4.2 resolver)

M4.1 stores both route types. M4.2 resolves them with this rule:

1. If the item has item-level routes in the branch, use the **active** item-level
   stations. Category routing is not added as a fallback.
2. Otherwise, use the **active** category-level routes for the item's category in
   the branch.
3. If neither exists, the item is **unrouted**. No kitchen ticket is generated;
   the item remains on the order and visible to the POS.

When multiple active routes match, the item is placed on each matching station's
ticket. This is how an order can span several stations. See
[`m4-kitchen-ticket-lifecycle.md`](./m4-kitchen-ticket-lifecycle.md) for the
implemented resolver and idempotency behavior.

### Inactive stations and unavailable menu targets

- Inactive stations keep their routes. The M4.2 resolver skips inactive
  stations; reactivating a station restores its existing routes.
- An item-level route to an inactive station is unrouted; it does not fall back
  to an active category route.
- Archived menu items/categories and branch availability remain governed by the
  existing M3 menu resolution. M4.1 does not duplicate those rules.
- Open tickets for a station that is later deactivated are not automatically
  cancelled. They remain readable and completable by authorized kitchen staff.

### Multiple stations per order

One **active** ticket exists per `(order, station)`. An order whose items route
to several stations therefore produces several active tickets. An order can
also retain items that are unrouted; those items have no ticket.

When all items on a station ticket are cancelled, the ticket remains as
historical `cancelled` work. If new items are later routed to that station while
the order is still accepted, M4.2 creates a new ticket generation rather than
reopening the cancelled ticket.

## 4. Ticket integrity and idempotency

- `kitchen_tickets` has `unique (order_id, station_id, generation)` and a partial
  unique index that allows at most one non-cancelled ticket per
  `(order_id, station_id)`. M4.2 generation reuses the active ticket or inserts
  the next generation after cancellation:
  `insert ... on conflict (order_id, station_id, generation) do nothing`.
- `kitchen_ticket_items` has `unique (ticket_id, order_item_id)` so the same
  order item cannot appear twice on one ticket.
- `kitchen_ticket_items` carries `order_id`, `branch_id`, and
  `organization_id` so composite foreign keys can prove that:
  - the ticket belongs to that order, branch, and organization; and
  - the order item belongs to the same order, branch, and organization.
- A ticket item therefore cannot reference an order item from another order,
  branch, or organization.
- Ticket statuses are `pending`, `preparing`, `ready`, `completed`, and
  `cancelled`. Cancelled tickets require `cancelled_at`, a non-empty
  `cancellation_reason`, and either a staff actor or a `system` actor with a null
  staff id.
- M4.2 adds independent `kitchen_ticket_items.status` and lifecycle timestamps,
  along with the transition, exact aggregate, and cancellation rules.

## 5. Authorization and RLS

| Table | Owner/Admin/Manager | Kitchen Staff | Cashier | Other branch | Other organization | Anon |
| --- | --- | --- | --- | --- | --- | --- |
| `kitchen_stations` | read in branch | read in branch | none | none | none | none |
| `kitchen_station_menu_categories` | read in branch | read in branch | none | none | none | none |
| `kitchen_station_menu_items` | read in branch | read in branch | none | none | none | none |
| `kitchen_tickets` | read in branch | read in branch | none | none | none | none |
| `kitchen_ticket_items` | read in branch | read in branch | none | none | none | none |

- Policies reuse `authz.has_branch_role(branch_id, array['owner','admin','manager','kitchen_staff'])`.
- Organization-scoped Owner/Admin access therefore covers all branches in the
  organization; branch-scoped roles are limited to their assigned branch.
- Kitchen Staff do not gain access to unrelated staff records, subscriptions, or
  administrative tables. Existing M2/M3 policies are unchanged.
- Direct client writes are denied by omitted grants; M4.2 writes must go through
  reviewed RPCs.

## 6. Implemented in M4.2

- Ticket generation on order acceptance, including idempotent and concurrent
  behavior, with a new generation when a station ticket was previously cancelled.
- Independent ticket-item lifecycle RPCs and exact aggregate-status guards.
- Order and order-item cancellation propagation into kitchen state. Removal is
  allowed for pending/preparing/ready kitchen work even when the order is already
  preparing/ready; completed work blocks removal. Whole-order cancellation may
  cancel completed work with audit history.
- Staff/system cancellation actor domains with no order-submitter fallback, and
  immutable cancellation attribution once recorded.
- Audit records for ticket creation, ticket status changes, and item status
  changes, including cancellation actor metadata.
- Read-only `list_kitchen_routing_issues` diagnostics for inactive routing.
- A final database invariant that recalculates parent ticket aggregates for
  direct item-status writes and rejects active items under cancelled tickets.

See [`m4-kitchen-ticket-lifecycle.md`](./m4-kitchen-ticket-lifecycle.md).

## 7. Deferred to later milestones

- Station-specific staff assignments. M4.1 intentionally uses branch-level
  authorization. Station-level assignment can be added later if operations need
  kitchen staff to see only their own station's tickets.
- Realtime publications/subscriptions and KDS frontend work.
- Kitchen station management UI.
- Guest ordering integration.
- Hosted Development and Production migration rollout.
