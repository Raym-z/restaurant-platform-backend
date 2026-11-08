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

Exact channel names, event payloads, Supabase Realtime publication configuration, filtering strategy, and client synchronization implementation will be defined alongside the data model and contracts.
