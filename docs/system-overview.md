# System Overview

## 1. Purpose

This repository provides the shared backend infrastructure for a multi-tenant restaurant SaaS platform. It connects three independently deployed applications through shared data, authorization rules, and backend contracts.

## 2. Applications and boundaries

| Repository | Primary users | Responsibility |
|---|---|---|
| `restaurant-pos` | Restaurant staff | Staff administration, POS, tables, orders, cash payments, queue operations, reports, KDS, and restaurant configuration. |
| `restaurant-ordering` | Restaurant guests | Public QR menu and guest order submission without requiring customer accounts. |
| `restaurant-waitlist` | Customers and restaurant guests | Universal customer accounts and public branch waitlist. |
| `restaurant-platform-backend` | All applications | Shared database, migrations, RLS, server-side rules, functions, shared types, and contracts. |

Each frontend repository owns its UI, interactions, and application-specific presentation logic. This backend repository is the source of truth for shared data structures and authoritative business rules. Critical rules must be enforced by trusted backend logic even if a frontend also performs validation or calculations for user experience.

For example, a frontend may display an estimated order total, but the backend must recalculate and validate prices, options, discounts (if supported), taxes/fees (if supported), and the authoritative total before persisting an order.

## 3. Infrastructure model

- One Supabase project is used per environment (development, staging, production).
- PostgreSQL stores authoritative application records.
- Supabase Auth authenticates registered staff and customer accounts.
- Staff and customer identities are separate authorization domains; neither identity grants the other's permissions.
- RLS and trusted server-side authorization protect data and operations.
- Edge Functions or another approved server-side mechanism handle operations that must not trust a browser client.
- Realtime communicates persisted changes to authorized clients; it is not the source of truth.

## 4. Tenant hierarchy

```text
Platform
├── Organization A
│   ├── Branch A1
│   └── Branch A2
└── Organization B
    ├── Branch B1
    └── Branch B2
```

- Platform-level administration manages organizations.
- An organization represents one restaurant business and owns its branches.
- A branch belongs to exactly one organization.
- Staff accounts belong to exactly one organization. Cross-organization staff membership is not supported.
- A staff member may be assigned to one or multiple branches within their organization, subject to role and permission rules.
- Each account can belong to only one organization. An organization starts with one branch on the permanent Free plan; an Organization subscription unlocks additional branches according to its entitlements.
- Organization-owned records must be scoped to an organization; branch-specific records must also be scoped to a branch where appropriate.
- Customer accounts are platform-wide and may interact with multiple restaurants through customer-facing features.

The backend must derive or validate tenant access from authenticated identity and trusted authorization data. Client-supplied IDs are selectors, not proof of permission.

## 5. Identity domains

### Staff
Staff authenticate through Supabase Auth to use POS. Each staff account is associated with exactly one organization. Its effective access is determined by role/permissions and branch assignments within that organization. Staff cannot switch to or access another organization.

### Customers
Customers have universal platform-wide accounts used by the waitlist application. Customer identity does not confer staff permissions. Customer data access is limited to the customer's own records and explicitly public information.

### Guest ordering
Guests do not need to register or log in to place QR orders. Guest authorization uses custom, short-lived/revocable guest session tokens rather than creating Supabase Auth users or premade Auth accounts for tables. A guest token is scoped to one active dining session and the permitted ordering operations. It is not a general user identity and cannot authorize staff operations.

## 6. Core domain capabilities

The backend is expected to support:
- Organizations, branches, plans, subscriptions, and entitlements.
- Staff identities, organization association, roles, permissions, and branch assignments.
- Customer profiles.
- Menus, categories, items, and branch availability/pricing rules (to be finalized).
- Tables and reusable table QR identifiers.
- Dining sessions and per-device guest session tokens.
- Orders and order items.
- Cash payment records and payment settlement state.
- Waitlist entries and queue status.
- Audit and operational records.

Exact entities, columns, constraints, and lifecycle rules are specified conceptually in `data-model.md`; they are not yet an approved SQL schema.

## 7. Cross-application flows

### QR ordering and dining sessions
1. A permanent table QR identifies its organization, branch, and table. It is a public locator, not a staff credential or a guest authorization secret.
2. When scanned, the backend resolves the table and checks for an active dining session.
3. If an active session exists, the guest device joins it. If none exists, the backend atomically creates a new active dining session and joins the device to it.
4. The backend issues a cryptographically secure guest token for that device, scoped to that dining session. Other devices scanning the same table QR receive their own tokens for the same active session.
5. The guest submits an order using the token. The backend validates the token, session state, table/branch context, menu availability, prices, and order contents before persisting the order.
6. POS and KDS receive authorized updates about persisted orders.
7. When the entire dining-session balance is successfully settled, the backend closes the session and invalidates all guest tokens associated with it.
8. A later scan of the same permanent table QR creates a new dining session if no active one exists.

Session creation must be concurrency-safe: simultaneous first scans of the same table must resolve to one active session, not create competing active sessions. Guests cannot select arbitrary session IDs or reopen closed sessions.

### Waitlist
1. A customer opens the waitlist page for a specific branch, typically through that branch's entrance QR or URL.
2. The customer authenticates or registers where required.
3. Backend validates eligibility and creates a branch-scoped queue entry.
4. Optional geolocation verification is performed server-side when enabled for the branch. Browser GPS is a presence signal, not proof of identity.
5. Authorized staff manage the queue through POS; customer-facing status is limited to the relevant customer's permitted information.

### Cash payment and session settlement
1. Cashier selects an order or the applicable outstanding dining-session balance.
2. POS submits the amount received and an idempotency key.
3. Backend validates the current outstanding balance, payment state, and staff authorization; it calculates or verifies change and records the payment.
4. The backend recalculates the dining-session outstanding balance transactionally.
5. The dining session closes only when its entire outstanding balance is zero and settlement is successful. An individual payment does not close the session if a balance remains.

The initial release presents one consolidated bill for the entire dining session and accepts one full-settlement cash payment. Split bills, partial payments, and payment allocation across customers or items are not implemented. Keep payment records separate from dining sessions and preserve a one-to-many-capable data model for future payment records, without exposing multiple/partial payment workflows in the initial release.

## 8. Source-of-truth rules

- PostgreSQL is authoritative for persisted state.
- Backend authorization is authoritative for access decisions.
- Realtime is a notification mechanism, not a replacement for database reads.
- Shared contracts in this repository are authoritative for consumers.
- Frontend state and client-submitted tenant identifiers, prices, totals, session IDs, or payment status are never security authorities.

## 9. Scope decisions

- One shared Supabase project per environment.
- Each staff account belongs to exactly one organization and may have assignments to multiple branches within it.
- Customers have universal customer accounts, separate from staff authorization.
- Guest QR ordering does not require a customer account or Supabase Auth guest user.
- Permanent table QR codes identify tables; backend-managed dining sessions are temporary.
- Scanning a table QR automatically joins the active dining session or atomically creates one if none exists.
- Each guest device receives its own scoped guest token; tokens are invalidated when the session closes.
- A dining session closes when its entire outstanding balance is successfully settled.
- Each dining session has one consolidated bill and one full-settlement payment in the initial release; split bills and partial payments are out of scope. The data model should remain extensible for future payment records.
- Cash is the only POS order payment method in the initial release. Payment gateway, card, e-wallet, and online order-payment integrations are excluded from the initial release.
- Free is a permanent plan with all POS features and a one-branch limit. An Organization subscription unlocks additional branches according to plan entitlements. One account belongs to one organization, and one subscription covers all of that organization’s branches.
- Organization subscriptions follow Active → Expired → Grace Period → Restricted. During the grace period, normal operations continue. In Restricted state, staff can log in and view historical data; existing orders/sessions can be completed and settled, but new orders/sessions and organization administration are blocked. Owner and Admin retain subscription-page read access; only Owner can initiate renewal or change plans. Owner and Admin can manage billing contact information. Renewal restores normal access. Free organizations do not expire.
- Subscription billing is separate from POS order payments. The launch billing provider and payment integration remain to be decided.

## 10. Remaining design decisions

The following remain to be finalized before implementation: exact entity relationships and columns; staff role/permission granularity and invitation flow; customer registration/verification details; menu pricing/availability rules; order and item status transitions; payment correction, void, and refund rules (split bills and partial payments are excluded from the initial release); waitlist lifecycle and duplicate-entry rules; paid subscription plans, branch entitlements, billing provider/integration, and exact grace-period duration; exact guest-token expiry/rotation policy; and API/RPC boundaries.
