# Realtime Architecture

## 1. Purpose

Define how real-time notifications keep POS, KDS, ordering, and waitlist clients informed about persisted changes.

## 2. Source of truth

PostgreSQL is the authoritative source of persisted application state. Realtime is a notification and synchronization mechanism; clients must not treat event delivery as guaranteed or as a replacement for database reads.

## 3. Initial use cases

- New orders becoming visible to POS and KDS.
- Order and preparation status changes.
- Dining-session lifecycle changes.
- Queue entry and queue status changes.
- Relevant table availability changes, if required by the agreed workflow.

## 4. Authorization

- Every subscription must be scoped to the caller's authorized organization and branch.
- Customer subscriptions must be limited to the customer's own permitted records.
- Guest ordering access must be limited to the valid dining session.
- Event payloads must not reveal unrelated tenant data or unnecessary personal information.
- Authorization must also be enforced for the operation that changes the underlying record.

## 5. Event design

Events should identify the affected resource and communicate only the minimum information needed for the client to refresh or update its view.

Document for each event:
- Event name/type.
- Source table or operation.
- Resource identifier.
- Organization/branch scope where appropriate.
- Payload fields.
- Authorized subscribers.
- Client recovery behavior.

Avoid making a client depend on an event payload as the only copy of important business data.

## 6. Delivery and recovery

Clients must handle:
- Initial data load before or during subscription setup.
- Temporary disconnection.
- Reconnection.
- Duplicate events.
- Delayed or out-of-order events.
- Missed notifications.

After reconnecting, clients should fetch the current authorized persisted state and reconcile their local view.

## 7. KDS considerations

KDS is part of the POS repository. It should load active branch orders from persisted data, then use realtime notifications to detect changes. Order state transitions must be validated by the backend. KDS must not be able to subscribe to another organization's or unauthorized branch's orders.

## 8. Waitlist considerations

The POS staff interface may subscribe to queue changes for authorized branches. Customer-facing waitlist views must receive only the relevant customer's permitted status information.

## 9. Operational guidance

- Keep subscriptions narrowly scoped.
- Avoid unnecessary high-volume events.
- Do not publish secrets or sensitive customer data.
- Monitor reconnect behavior and subscription errors.
- Test authorization for each channel/table/event path.

## 10. Pending decisions

Exact channel names, event payloads, Supabase Realtime publication configuration, filtering strategy, and client synchronization implementation are defined for the kitchen display system in section 11. Other domains remain pending.

M3 does not enable a publication for tables, dining sessions, or orders.
M4.3 enables publication only for the five kitchen tables listed below.
Publication for other domains still requires an approved tenant/branch
subscription design.

## 11. Kitchen Display System Realtime (M4.3)

### 11.1 Publication

The `supabase_realtime` publication includes:

- `public.kitchen_tickets`
- `public.kitchen_ticket_items`
- `public.kitchen_stations`
- `public.kitchen_station_menu_items`
- `public.kitchen_station_menu_categories`

`kitchen_station_menu_items` and `kitchen_station_menu_categories` use
`replica identity full` because route removal is a `DELETE` event and Realtime
must evaluate the branch-scoped `SELECT` policy against the old row. Tickets,
ticket items, and stations are never deleted by normal application flows, so
they keep the default primary-key replica identity.

Publication membership is idempotent. Re-applying the migration does not add a
table twice.

### 11.2 Channel and filters

Use one branch-scoped channel:

```text
channel: kds:branch:<branchId>
filters:
  kitchen_tickets:                  branch_id = eq.<branchId>
  kitchen_ticket_items:             branch_id = eq.<branchId>
  kitchen_stations:                 branch_id = eq.<branchId>
  kitchen_station_menu_items:       branch_id = eq.<branchId>
  kitchen_station_menu_categories:  branch_id = eq.<branchId>
```

Channel names and filters are client conveniences. **Database RLS is the
authorization boundary.** A client must never rely on its own filter or channel
name to prevent cross-branch delivery.

`kitchen_ticket_items` does not contain `station_id`. For v1, subscribe at branch
level and map `ticket_id` to a station using the KDS read model. Do not add a
denormalized station identifier solely to simplify subscriptions unless a
measured requirement justifies it.

### 11.3 Observable events

The KDS must observe both ticket and ticket-item events:

| Table | INSERT | UPDATE | DELETE |
| --- | --- | --- | --- |
| `kitchen_tickets` | New generation | Aggregate status/timestamps/cancellation | Not used |
| `kitchen_ticket_items` | Item added to a ticket | Item preparation progress/cancellation | Not used |
| `kitchen_stations` | Station created | Rename/deactivate/reactivate | Not used |
| `kitchen_station_menu_items` | Route added | — | Route removed |
| `kitchen_station_menu_categories` | Route added | — | Route removed |

A `kitchen_tickets` subscription alone is insufficient: an item can move from
`pending` to `preparing` while the ticket is already `preparing`, so no ticket
row update occurs. Clients must subscribe to `kitchen_ticket_items` as well.

Do not subscribe to `orders` or `order_items` for KDS item progress. That would
increase event volume and duplicate the independent kitchen state.

### 11.4 Event semantics and recovery

Realtime events are notifications, not authoritative payloads. After receiving
an event:

- **Ticket INSERT/UPDATE:** refetch the affected ticket or the active list via
  `public.list_kitchen_tickets` / `public.get_kitchen_ticket`.
- **Ticket-item INSERT/UPDATE:** refetch the parent ticket using `ticket_id`.
- **Station or route event:** refetch station configuration via
  `public.list_kitchen_stations`.
- Debounce bursts per ticket (for example one refetch per 250–500 ms).
- Ignore events for tickets outside the current branch or station view.
- Reconcile by ticket/item identifier and `updatedAt`; tolerate duplicate,
  delayed, and out-of-order events.

Recovery sequence:

1. Load authoritative state with the read RPC.
2. Subscribe to `kds:branch:<branchId>`.
3. On reconnect or subscription error, refetch the active list.
4. Refetch when the screen becomes visible again.
5. Poll every 30–60 seconds while visible when Realtime is unavailable.
6. Never assume guaranteed delivery; there is no server-side event cursor.

### 11.5 Verification status

The publication, replica identity, channel contract, and client recovery model
are implemented. They are **not verified end-to-end** in this environment
because Docker/WSL is unavailable and the local Supabase stack cannot start.

The exact missing tests are:

- Branch A Kitchen Staff receives branch A ticket and ticket-item events.
- Branch A Kitchen Staff receives no branch B events.
- Cross-organization events are not delivered.
- Cashier receives no kitchen events.
- Anonymous receives no kitchen events.
- Station and route events are branch-scoped.
- Ticket INSERT/UPDATE is observable.
- Ticket-item INSERT/UPDATE is observable even when the aggregate ticket status
  does not change.
- Route DELETE is delivered with full old-row identity.
- Reconnect followed by a full refetch restores persisted state.

Until those tests pass, `BLK-008` remains open and polling is the supported
operating mode. Do not claim production-ready Realtime delivery.
