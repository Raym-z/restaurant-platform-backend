# Data Model

## 1. Purpose and Status

This document defines the approved conceptual domain model and the relationships for the initial restaurant platform. It is not a finalized SQL schema. Exact table names, columns, keys, constraints, indexes, enum values, and function contracts must still be reviewed before migrations are written.

The model follows the platform's multi-tenant hierarchy. An organization owns one or more branches; business records are organization-owned and branch-scoped where appropriate. Backend-enforced integrity and authorization rules apply regardless of which frontend initiates an operation.

## 2. Tenant and Organization Domain

### Platform

Represents the SaaS platform and its platform-level administration. Platform administration is separate from restaurant organization roles. Platform Admins manage platform operations, organizations, plans, entitlements, and platform settings. They do not automatically receive access to restaurant business data; exceptional access must be explicitly granted and audited.

### Organization

Represents an independent restaurant business using the platform. An organization has exactly one Owner and may have multiple staff members and branches. Organization-level subscription and plan entitlements apply across its branches.

### Branch

Represents a physical restaurant location belonging to exactly one organization. Branch-scoped operational records, such as tables, dining sessions, orders, and queue entries, reference a branch and its owning organization. The backend must prevent cross-organization relationships.

**Relationships and rules:**

- One organization can have multiple branches, subject to its plan's branch limit.
- A branch belongs to exactly one organization.
- The Free plan permits one organization with one branch; the Organization plan unlocks additional branches according to its entitlements.
- Reaching the branch limit blocks creation of additional branches but does not remove access to existing branches.

## 3. Identity and Access Domain

### Staff Identity and Profile

Each staff member uses one Supabase Auth user identity and has a corresponding staff profile. A staff identity belongs to exactly one organization; the initial model does not support one staff identity belonging to multiple organizations.

### Organization Staff Role Assignment

A staff member may be assigned multiple fixed roles within their organization. Effective permissions are the combination of the assigned roles, constrained by the staff member's branch assignments and the organization's access state. There is no custom role editor or per-permission override in the initial release.

The fixed roles are:

- **Owner** — exactly one per organization; organization-wide authority.
- **Admin** — organization administration, with scope determined by explicit organization-wide or assigned-branch scope.
- **Manager** — operational management within assigned branches.
- **Cashier** — cashier and payment workflows within assigned branches.
- **Kitchen Staff** — kitchen and preparation workflows within assigned branches.

Role permissions and scope are enforced by trusted backend logic and database policies, not merely by frontend navigation or UI visibility. Admin scope must be represented explicitly; an Admin must not automatically be assumed to have organization-wide access unless assigned that scope.

### Staff Branch Assignment

Associates staff with the branches they may access.

- Owner access is organization-wide.
- Manager, Cashier, and Kitchen Staff access is limited to assigned branches.
- Admin access may be organization-wide or limited to assigned branches, according to the explicit scope assigned to that Admin.

### Platform Admin Identity

Platform Admin is a platform-level authorization role, separate from the five organization roles. Platform Admin accounts are provisioned by an authorized Platform Admin through a controlled process; there is no public signup or self-promotion path. Initial provisioning occurs securely outside public registration.

### Customer Identity and Profile

Represents a platform-wide customer account used by the waitlist application. Customer identity is separate from staff identity and staff authorization. A customer may have active waitlist entries at multiple restaurant branches simultaneously.

## 4. Restaurant Configuration Domain

### Menu Category

Groups menu items within an organization. Categories may be made unavailable at individual branches without requiring a separate organization-wide menu for every branch.

### Menu Item

Represents a sellable item owned by an organization, including its descriptive information and default/base price. Each branch can independently control whether an item is available and may override its selling price. This supports centralized menu management while allowing branch-level operational differences.

### Modifier Group and Modifier Option

A modifier group defines a set of options that can be selected for a menu item, such as size, milk type, or toppings. Groups define selection constraints, including minimum and maximum selections.

Modifier groups may be reused across menu items, while item-specific groups are also supported. Reusable groups should be the normal approach where options are shared.

The selected modifier options, their names, and their price effects must be captured in the order-item snapshot so later menu or modifier edits do not change historical orders.

### Table

Represents a physical table at a branch. A table may have at most one active dining session at a time. When its active dining session is closed, the table becomes available for a subsequent session.

Table occupancy is coordinated with dining-session state; it is not an independent, conflicting source of truth.

### Dining Session

Represents a group dining visit at a branch, normally associated with one table. A dining session can contain multiple orders submitted by different customers or devices. Multiple devices scanning the same permanent table QR join the same active session.

The backend resolves the table QR to the active session and creates a session if none exists. Session creation must be atomic so concurrent scans cannot create duplicate active sessions for the same table.

The session closes only after the entire outstanding bill has been successfully settled. During a restricted organization subscription state, existing sessions may be completed and paid, but new sessions cannot be created.

### Table QR and Guest Device Token

A permanent table QR identifies the restaurant, branch, and table; it is not itself a session credential.

On scan, a trusted backend operation resolves or creates the active dining session and issues a separate random guest token scoped to that session and device.

- Only token hashes are stored server-side.
- Raw tokens are delivered only through trusted backend logic.
- Raw tokens must not be persisted in browser storage as a shared credential.
- Tokens are revoked or invalidated when the session closes or the token expires.
- The backend validates the token, session state, and submitted order contents.
- Guest ordering does not require customer login or registration.
- The system must not create premade Supabase Auth users for tables.

## 5. Ordering Domain

### Order

Represents an order associated with an organization, branch, and dining session. Multiple orders may belong to one dining session.

Orders are submitted by guest devices or entered by authorized staff, depending on the workflow. The backend validates menu availability, modifiers, quantities, prices, tenant/branch ownership, and session state at submission time.

### Order Item

Represents a line item within an order. It preserves a historical snapshot of at least:

- Item name.
- Unit price.
- Quantity.
- Selected modifiers and options.
- Applicable price adjustments.

Later changes to menu items, prices, or modifiers must not rewrite past transactions.

Each order item has its own preparation status so different items in the same order can progress independently. The order's overall fulfillment status is coordinated with its item statuses and the order lifecycle.

### Order Lifecycle

The initial proposed order lifecycle is:

| Status    | Meaning                                  |
| --------- | ---------------------------------------- |
| Pending   | Submitted and awaiting staff acceptance. |
| Accepted  | Accepted by staff.                       |
| Preparing | Kitchen preparation is underway.         |
| Ready     | Preparation is complete.                 |
| Served    | Delivered to the customer.               |
| Cancelled | Cancelled before completion.             |

The backend validates allowed transitions. Fulfillment status is separate from payment status; an order's preparation progress must not be used as a substitute for bill or payment state.

Exact transition rules, including exceptional cancellation and item-level transitions, remain part of the detailed contract review.

## 6. Billing and Payment Domain

### Bill

A dining session has one consolidated bill that aggregates all eligible orders in that session.

The bill represents the total outstanding amount for the session and is settled as a whole in the initial release.

There are no split bills, partial payments, per-customer allocations, or item-level payment allocations in the initial workflow.

### Payment

Payment is a separate record associated with the bill, organization, and branch.

The initial release supports one successful full-settlement cash payment per bill.

Payment data should capture:

- Amount due at payment time.
- Cash received.
- Change returned.
- Payment status and timestamp.
- Staff member who recorded it.

Although only one full-settlement payment workflow is implemented initially, keeping payment records separate from bills preserves a path for future payment methods and workflows. Do not implement split or partial payment behavior now.

A dining session closes only when its entire outstanding bill has been successfully settled.

Existing orders and sessions may be completed and paid while an organization's subscription is restricted; new orders and sessions are blocked in that state.

Payment corrections, voids, refunds, reconciliation, and exceptional adjustments require explicit audited workflows. Completed orders and settled payments are historical records and must not be silently overwritten.

## 7. Waitlist Domain

### Queue Entry

Represents a customer's place in a branch-specific waitlist. Each entry is associated with one customer and one branch and includes party size, required contact details, lifecycle state, and timestamps.

A customer may have only one active queue entry per branch but may have active entries at multiple branches simultaneously. The backend enforces this invariant.

### Queue Ordering and Staff Override

The default queue order is first-come, first-served, based on queue-entry creation time.

Authorized staff may manually reorder entries to handle operational exceptions. Every manual reorder or priority override must be recorded in the audit history.

### Queue Lifecycle

The initial proposed lifecycle is:

| Status    | Meaning                                           |
| --------- | ------------------------------------------------- |
| Waiting   | Customer is in the queue.                         |
| Notified  | Customer has been called or notified.             |
| Seated    | Customer has been seated.                         |
| Cancelled | Customer or authorized staff cancelled the entry. |
| No-show   | Customer did not arrive after being called.       |

The backend validates status transitions. Notification timing, no-show handling, and any branch-specific configuration require detailed workflow definitions.

### Customer Presence and Geolocation

A branch may optionally enable geolocation checks when a customer joins its waitlist.

If enabled, location is requested at join time and the backend calculates distance using the branch's coordinates and configured radius.

Geolocation is a presence signal, not proof of physical presence, because GPS can be spoofed. Precise coordinates should not be retained longer than necessary for the check.

## 8. Subscription Domain

### Subscription

Represents an organization's subscription to the SaaS platform. A subscription belongs to the organization, not an individual branch, and its entitlements apply across all branches in that organization.

### Plan and Entitlement

Defines the available plans, branch limits, and other platform entitlements.

- The Free plan is permanent, requires no payment details, and permits one branch.
- The Organization plan unlocks multiple branches according to its configured entitlement.
- The backend enforces branch limits and subscription restrictions.

The subscription lifecycle includes active, expired, grace-period, and restricted states.

During the grace period, normal operations continue while the owner is prompted to renew.

After the grace period, staff may log in and view historical data, but new operational activities and organization administration are blocked.

Owner and Admin retain access to subscription information and subscription-related contact details. Only the Owner may initiate renewal, upgrade, downgrade, or plan changes.

Free organizations do not expire and are not subject to this lifecycle.

Subscription billing provider, payment workflow, exact grace-period duration, and detailed entitlement catalog remain to be designed.

Subscription billing is separate from restaurant order payment.

## 9. Audit and Operational Records

Audit records capture sensitive or consequential actions, including:

- Staff role assignments, branch assignments, and access-scope changes.
- Branch and organization configuration changes.
- Order cancellation, adjustment, and exceptional correction.
- Payment recording, void, correction, or refund.
- Dining-session closure and guest-token revocation.
- Queue reordering and priority overrides.
- Subscription and entitlement changes.
- Organization suspension, deletion requests, and platform administrator intervention.

Audit records should identify the actor, organization and relevant branch context, action, timestamp, and appropriate change metadata.

They must be protected against unauthorized modification.

Exceptional Platform Admin access to restaurant business data must be explicitly authorized and audited.

## 10. Cross-Domain Integrity Requirements

- Every branch belongs to exactly one organization.
- Organization and branch references on a business record must be consistent.
- Staff identities belong to exactly one organization; staff branch access follows explicit assignments and role scope.
- Orders, bills, payments, tables, and dining sessions must not cross tenant or branch boundaries.
- A dining session must belong to the same branch as its table and its orders.
- A table may have at most one active dining session at a time.
- A bill belongs to one dining session and aggregates its eligible orders.
- A payment references the bill it settles and must not exceed the permitted settlement amount under the initial full-settlement workflow.
- A guest token resolves only to its associated valid session and device context.
- A customer may have at most one active waitlist entry per branch.
- Customer access is restricted to the customer's own protected records.
- Staff access follows organization membership, role assignments, explicit role scope, branch assignments, and organization subscription state.
- Historical order and payment snapshots remain stable when menu, modifier, or configuration data changes.

## 11. Approved Detailed Business Rules

The following rules were reviewed and approved for the initial release. They refine the conceptual entities above and must be reflected in the eventual schema, backend operations, and API/RPC contracts.

### 11.1 Menu Price Snapshots and Branch Overrides

- The authoritative menu-item and modifier prices are validated by the backend and snapshotted when an order is submitted.
- Changes to menu prices after submission must not change the price of an existing submitted order or its historical order-item snapshot.
- A branch inherits the organization's base menu-item price until that branch has an explicit price override.
- Updating an organization's base price affects branches that currently inherit the base price. It does not overwrite explicit branch overrides.
- Removing a branch price override causes that branch to inherit the current organization base price for future orders. It does not rewrite previously submitted orders.

### 11.2 Branch Tax and Service-Charge Configuration

- The organization may define default tax and service-charge configuration.
- A branch may use the organization defaults or configure branch-specific overrides.
- Tax and service-charge rules may be percentage-based or fixed-amount rules, with independent enable/disable controls.
- The exact calculation base, ordering, compounding behavior, tax inclusivity, and applicability to discounts or modifiers must be defined in the bill-calculation contract before implementation.

### 11.3 Bill Calculation and Finalization

- Bill totals are calculated using integer minor currency units and a single documented rounding policy. Floating-point arithmetic must not be used for monetary values.
- The bill is calculated or refreshed using the applicable branch configuration and eligible submitted orders.
- When staff explicitly finalizes a bill, the backend validates the session and eligible orders, calculates the totals, and freezes the resulting bill calculation for settlement.
- Later changes to menu prices, modifier prices, tax settings, service-charge settings, or discounts must not silently alter a finalized bill.
- The exact rounding policy and the point at which each component is rounded must be specified consistently for line totals, discounts, tax, service charges, and the final amount.

### 11.4 Initial-Release Discounts

- The initial release supports staff-applied fixed-amount and percentage discounts.
- Discount application must be permission-controlled and recorded in the audit history, including the actor and relevant discount details.
- Discount codes, automated promotions, and a full promotions engine are outside the initial-release scope.
- Discount scope (whole bill versus eligible line items), stacking rules, limits, and calculation order remain to be specified in the bill-calculation contract.

### 11.5 Order Immutability and Corrections

- Once submitted, an order must not be silently overwritten.
- Additional customer requests should normally be submitted as additional orders within the same dining session.
- Corrections and cancellations use explicit backend-enforced, permission-controlled, audited actions rather than direct mutation of historical order contents.
- Individual order items may be cancelled before or during preparation, subject to the actor's permissions and a recorded reason.
- An item that has already been served cannot be treated as an ordinary cancellation; it requires an explicit correction or refund workflow.
- The detailed rules for whether cancellation affects billable totals, and how kitchen notifications are handled, must be defined in the order and billing contracts.

### 11.6 Order Fulfillment and KDS

- Order fulfillment is independent of payment state and dining-session settlement.
- Each order item has its own preparation/fulfillment status so items in one order can progress independently.
- An order becomes Served when all of its non-cancelled items have been marked served.
- An order must not be considered served merely because its items are Ready.
- The backend coordinates and validates item-level and order-level status transitions. The exact transition matrix and exceptional paths remain to be specified.

### 11.7 Bill Finalization and Subsequent Orders

- Bill finalization is an explicit staff action. It is not triggered automatically by an order becoming served or by a customer requesting checkout.
- The backend validates eligible orders and session state before finalizing the consolidated bill.
- A finalized bill is immutable.
- If an unpaid finalized bill needs correction, staff must use an explicit audited workflow to reopen it or void it and create a replacement. The precise authorization, status transitions, and historical linkage must be defined before implementation.
- The initial release continues to support one consolidated bill and one full-settlement cash payment per dining session; no split bills or partial payments are introduced by these rules.

### 11.8 Waitlist Ordering and Lifecycle

- Queue entries are ordered first-come, first-served by their creation time by default.
- Authorized staff may manually reorder entries or apply a priority override for operational reasons. Each such action must be recorded in the audit history.
- The initial queue lifecycle is Waiting, Notified, Seated, Cancelled, and No-show.
- Backend logic validates status transitions. Notification timing, no-show thresholds, and branch-specific queue configuration remain to be specified in the queue workflow contract.

## 12. Remaining Decisions Before Schema Implementation

The conceptual model and the detailed rules in this document have been approved. The following details still require design and review before SQL migrations are written:

1. Exact entity/table names, columns, primary and foreign keys, nullability, and database representations of the approved concepts.
2. Exact role-permission matrix and representation of organization-wide versus branch-scoped Admin access.
3. Exact menu/category branch availability behavior and modifier pricing/selection constraints.
4. Exact table and dining-session state transitions, session expiry behavior, and concurrent session-creation implementation.
5. Guest token expiry, rotation, device limits, revocation, and cleanup schedule.
6. Exact order and order-item status transition matrix, cancellation authorization, cancellation effects on bills, and KDS notification behavior.
7. Bill calculation details: tax inclusivity, calculation base, tax/service-charge ordering, discount scope and stacking, calculation sequence, and the single rounding policy.
8. Finalized-bill reopening/voiding authorization, status transitions, replacement linkage, and audit requirements.
9. Payment idempotency, cash reconciliation, and audited correction/void/refund workflows.
10. Queue notification timing, no-show rules, queue expiry, and staff override permissions.
11. Subscription plan catalog, entitlements, billing workflow, grace-period duration, and renewal processing.
12. Audit metadata retention, archival, and legal/backup retention requirements.
13. Exact indexes, uniqueness constraints, database functions/RPC boundaries, grants, and concurrency/retry behavior.

Do not treat this conceptual model as a final table definition. SQL schema and migrations should be created only after the remaining detailed data-model decisions and dependent API/RPC contracts have been reviewed and approved.
