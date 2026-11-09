# M4.1 — Kitchen Infrastructure

M4.1 adds the database and authorization foundation for the Kitchen Display
System (KDS). It intentionally does **not** generate tickets, implement ticket
lifecycle RPCs, add realtime subscriptions, or change order lifecycle behavior.

## 1. Schema

| Table | Purpose |
| --- | --- |
| `public.kitchen_stations` | Branch-scoped kitchen stations with active/inactive state. |
| `public.kitchen_station_menu_categories` | Category-level menu routing to a station in a branch. |
| `public.kitchen_station_menu_items` | Item-level menu routing to a station in a branch. |
| `public.kitchen_tickets` | One ticket per `(order, station)`, linked to the order and branch. |
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

M4.1 stores both route types but does not resolve them. The intended M4.2 rule
is:

1. If the item has one or more active item-level routes in the branch, use those
   stations.
2. Otherwise, use the active category-level routes for the item's category in
   the branch.
3. If neither exists, the item is **unrouted**. No kitchen ticket is generated;
   the item remains on the order and visible to the POS.

This rule is a product decision for M4.2 and must be confirmed before ticket
generation is implemented. Alternatives (for example, treating category and item
routes as additive) are not implemented.

### Inactive stations and unavailable menu targets

- Inactive stations keep their routes. The M4.2 resolver skips inactive
  stations; reactivating a station restores its existing routes.
- Archived menu items/categories and branch availability remain governed by the
  existing M3 menu resolution. M4.1 does not duplicate those rules.
- Open tickets for a station that is later deactivated are not automatically
  cancelled by M4.1. M4.2 must decide whether to keep, hide, or cancel them.

### Multiple stations per order

One ticket exists per `(order, station)`. An order whose items route to several
stations therefore produces several tickets. An order can also retain items
that are unrouted; those items have no ticket.

## 4. Ticket integrity and idempotency

- `kitchen_tickets` has `unique (order_id, station_id)`. This is the idempotency
  anchor for M4.2: generation can use
  `insert ... on conflict (order_id, station_id) do ...`.
- `kitchen_ticket_items` has `unique (ticket_id, order_item_id)` so the same
  order item cannot appear twice on one ticket.
- `kitchen_ticket_items` carries `order_id`, `branch_id`, and
  `organization_id` so composite foreign keys can prove that:
  - the ticket belongs to that order, branch, and organization; and
  - the order item belongs to the same order, branch, and organization.
- A ticket item therefore cannot reference an order item from another order,
  branch, or organization.
- Ticket statuses are `pending`, `preparing`, `ready`, `completed`, and
  `cancelled`. Cancelled tickets require `cancelled_at`,
  `cancelled_by_staff_id`, and a non-empty `cancellation_reason`.
- Lifecycle transitions and timestamp rules (for example, when `started_at` or
  `completed_at` must be set) are deferred to M4.2.

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

## 6. Deferred to later milestones

- Station-specific staff assignments. M4.1 intentionally uses branch-level
  authorization. Station-level assignment can be added later if operations need
  kitchen staff to see only their own station's tickets.
- Ticket generation during order creation or acceptance.
- Ticket lifecycle RPCs and item-level KDS transitions.
- Order status aggregation from ticket/item state.
- Realtime publications/subscriptions and KDS frontend work.
- Guest ordering integration.
