# API and RPC Contracts

## 1. Purpose

This document defines the API architecture, backend operation boundaries, RPC responsibilities, Edge Function responsibilities, authorization requirements, and communication contracts for the Restaurant Management Platform.

It serves as the implementation reference for all frontend applications and the shared backend repository.

The platform consists of four repositories:

| Repository                    | Responsibility                                                                              |
| ----------------------------- | ------------------------------------------------------------------------------------------- |
| `restaurant-platform-backend` | Database schema, migrations, RLS, RPCs, Edge Functions, shared contracts, and backend logic |
| `restaurant-pos`              | Staff-facing POS, organization management, branch administration, KDS, billing, and reports |
| `restaurant-ordering`         | Public QR-based customer ordering                                                           |
| `restaurant-waitlist`         | Customer accounts and restaurant waitlist                                                   |

All applications communicate with the same Supabase project within each environment.

The backend repository is the source of truth for API contracts and database-level business rules.

---

## 2. API Architecture

### 2.1 General Architecture

The platform uses Supabase as its backend infrastructure:

- PostgreSQL for persistent data.
- Supabase Auth for staff and customer authentication.
- Row Level Security (RLS) for data access control.
- PostgreSQL functions (RPCs) for atomic database operations.
- Supabase Edge Functions for trusted server-side workflows.
- Supabase Realtime for live operational updates.
- Supabase Storage for uploaded files and assets where required.

Frontend applications may communicate with Supabase directly when the operation is safe and protected by RLS.

Business-critical operations must use approved backend operations.

### 2.2 Backend Communication Methods

The platform uses four primary communication mechanisms.

#### A. Direct Supabase Queries

Used for operations that can safely be performed through the Supabase client with RLS enforcement.

Typical responsibilities:

- Retrieving organization and branch information.
- Retrieving menus and menu availability.
- Reading tables and operational data.
- Retrieving order and payment history.
- Reading customer profiles.
- Retrieving reports when the query is appropriately protected and does not require privileged business logic.

Direct queries must never bypass RLS.

Frontend filtering is not an authorization mechanism.

#### B. PostgreSQL RPCs

RPCs are used for database-centric operations requiring:

- Atomic transactions.
- Multiple related database changes.
- Business-rule enforcement.
- Concurrency protection.
- Idempotency.
- Validated state transitions.
- Consistent calculations.

Examples:

- Creating an organization and its initial branch.
- Creating or updating staff assignments.
- Submitting an order.
- Updating order preparation statuses.
- Finalizing a bill.
- Recording a payment.
- Updating waitlist entries.
- Enforcing subscription restrictions.

RPCs must be narrowly scoped and must not become unrestricted database access endpoints.

#### C. Supabase Edge Functions

Edge Functions handle trusted server-side workflows requiring orchestration, secrets, or external integrations.

Typical responsibilities:

- Issuing guest device tokens.
- Validating guest session credentials.
- Coordinating guest ordering workflows.
- Sending customer notifications.
- Integrating external services.
- Handling trusted file-processing workflows.
- Performing scheduled or system-triggered operations where appropriate.

Edge Functions may call PostgreSQL RPCs to perform atomic database operations.

Edge Functions must not duplicate authoritative business rules that belong in the database.

#### D. Supabase Realtime

Realtime is used to distribute operational changes to authorized clients.

Examples:

- Incoming orders displayed in KDS.
- Order status changes.
- Item preparation status changes.
- Waitlist updates.
- POS dashboard updates.

Realtime subscriptions must respect authorization and must not expose data across organizations or unauthorized branches.

---

## 3. Backend Responsibility Principles

### 3.1 Frontend Responsibilities

Frontend applications are responsible for:

- User interfaces and presentation.
- User interactions.
- Form validation for usability.
- Client-side state management.
- Display formatting.
- Navigation and application-specific workflows.
- Calling approved backend operations.
- Handling loading, success, and error states.

Client-side validation improves usability but does not establish data integrity or authorization.

### 3.2 Backend Responsibilities

The backend is responsible for:

- Authentication and authorization enforcement.
- Organization and branch access validation.
- Business-rule enforcement.
- Subscription entitlement enforcement.
- Transaction integrity.
- Data consistency.
- Pricing and billing calculations.
- Order and queue state transitions.
- Payment recording.
- Idempotency.
- Audit logging.
- Guest session security.
- Rate limiting.
- External service integrations.

Critical rules must remain enforced even if a frontend is modified, bypassed, or replaced.

### 3.3 Source of Truth

The backend is authoritative for:

- Organization ownership.
- Staff roles and branch assignments.
- Organization and branch subscription status.
- Menu availability and pricing.
- Submitted order contents and price snapshots.
- Order and item statuses.
- Dining session status.
- Bill calculations and finalized bill values.
- Payment records.
- Waitlist positions and statuses.
- Guest session validity.

The frontend must not assume that a previously retrieved value remains valid when submitting a mutation.

The backend must revalidate relevant data during execution.

---

## 4. Shared API Contracts

### 4.1 Canonical Contract Location

All shared API contracts must be maintained in:

`restaurant-platform-backend`

Recommended organization:

```text
restaurant-platform-backend/
├── src/
│   ├── contracts/
│   │   ├── common/
│   │   │   ├── response.ts
│   │   │   ├── errors.ts
│   │   │   ├── pagination.ts
│   │   │   └── filters.ts
│   │   ├── organization/
│   │   ├── branch/
│   │   ├── staff/
│   │   ├── menu/
│   │   ├── table/
│   │   ├── order/
│   │   ├── billing/
│   │   ├── payment/
│   │   ├── guest/
│   │   ├── customer/
│   │   ├── waitlist/
│   │   ├── subscription/
│   │   ├── reports/
│   │   └── platform-admin/
│   └── ...
```

The exact implementation structure may evolve, but contracts must have one canonical source.

Frontend repositories should consume or synchronize these shared definitions rather than independently inventing API payloads.

### 4.2 TypeScript and Runtime Validation

Shared contracts must provide:

- TypeScript request types.
- TypeScript response types.
- Runtime validation schemas.
- Standardized error definitions.
- Shared enums and status definitions where appropriate.

Use Zod or an equivalent runtime validation library.

Validate untrusted input at trusted backend boundaries, including Edge Functions and RPC inputs where appropriate.

Do not rely exclusively on TypeScript types because TypeScript types do not validate runtime requests.

### 4.3 Contract Compatibility

Changes to externally consumed Edge Function/API contracts must be versioned when necessary.

Internal RPC contracts may evolve through coordinated database migrations and frontend updates.

Avoid introducing unnecessary versioning for every internal function.

Breaking changes must be coordinated across dependent repositories.

---

## 5. Standard Request and Response Conventions

### 5.1 Request Context

Authenticated operations derive the user's identity from the authenticated Supabase session.

The backend must not trust client-supplied:

- User IDs.
- Organization IDs.
- Role assignments.
- Permissions.
- Subscription status.
- Entitlements.

Organization and branch IDs supplied by the client represent requested context only.

The backend must independently verify that the authenticated user has access to the requested organization and branch.

### 5.2 Success Response

Trusted Edge Function endpoints should use a consistent response envelope.

Example:

```json
{
	"success": true,
	"data": {
		"id": "resource-uuid"
	},
	"meta": null
}
```

For paginated responses:

```json
{
	"success": true,
	"data": [
		{
			"id": "resource-uuid"
		}
	],
	"meta": {
		"page": 1,
		"pageSize": 20,
		"hasMore": true,
		"nextCursor": "opaque-cursor"
	}
}
```

The exact response shape must be defined in the shared contracts and applied consistently.

Direct Supabase queries retain their native response format unless wrapped by an application service.

### 5.3 Error Response

Trusted API endpoints should return a standardized error envelope.

Example:

```json
{
	"success": false,
	"error": {
		"code": "ORDER_INVALID_STATUS",
		"message": "This order cannot be updated in its current state.",
		"details": null
	}
}
```

The backend must not expose:

- Raw SQL errors.
- Database stack traces.
- Internal implementation details.
- Service-role credentials.
- Guest token hashes.
- Sensitive authorization information.

Detailed errors may be recorded in secure server logs.

### 5.4 HTTP Status Codes

Use appropriate HTTP status codes for Edge Function/API endpoints.

| Status | Meaning                                                |
| ------ | ------------------------------------------------------ |
| 200    | Successful request                                     |
| 201    | Resource created                                       |
| 204    | Successful request without response body               |
| 400    | Invalid request                                        |
| 401    | Unauthenticated                                        |
| 403    | Authenticated but unauthorized                         |
| 404    | Resource not found or not accessible                   |
| 409    | Conflict with current resource state                   |
| 422    | Valid request structure but invalid business operation |
| 429    | Rate limit exceeded                                    |
| 500    | Unexpected server error                                |
| 503    | Temporarily unavailable                                |

Do not expose resource existence when doing so would reveal information across tenant boundaries.

---

## 6. Error Codes

Use centralized error definitions.

Suggested categories:

### Authentication

- `AUTH_REQUIRED`
- `AUTH_INVALID_TOKEN`
- `AUTH_SESSION_EXPIRED`
- `AUTH_ACCOUNT_INACTIVE`

### Authorization

- `PERMISSION_DENIED`
- `ORGANIZATION_ACCESS_DENIED`
- `BRANCH_ACCESS_DENIED`
- `ROLE_REQUIRED`

### Organization and Branch

- `ORGANIZATION_NOT_FOUND`
- `ORGANIZATION_ALREADY_EXISTS`
- `ORGANIZATION_DELETION_PENDING`
- `BRANCH_NOT_FOUND`
- `BRANCH_LIMIT_REACHED`
- `BRANCH_ALREADY_EXISTS`

### Subscription

- `SUBSCRIPTION_RESTRICTED`
- `SUBSCRIPTION_EXPIRED`
- `SUBSCRIPTION_PERMISSION_DENIED`
- `SUBSCRIPTION_LIMIT_REACHED`

### Menu

- `MENU_ITEM_NOT_FOUND`
- `MENU_ITEM_UNAVAILABLE`
- `INVALID_MENU_PRICE`
- `INVALID_MODIFIER_SELECTION`

### Table and Guest Sessions

- `TABLE_NOT_FOUND`
- `TABLE_QR_INVALID`
- `GUEST_TOKEN_INVALID`
- `GUEST_TOKEN_EXPIRED`
- `GUEST_SESSION_CLOSED`
- `GUEST_SESSION_NOT_FOUND`

### Orders

- `ORDER_NOT_FOUND`
- `ORDER_INVALID_STATUS`
- `ORDER_SUBMISSION_FAILED`
- `ORDER_ALREADY_PROCESSED`
- `ORDER_ITEM_UNAVAILABLE`
- `ORDER_MODIFICATION_NOT_ALLOWED`

### Billing and Payments

- `BILL_NOT_FOUND`
- `BILL_ALREADY_FINALIZED`
- `BILL_REOPEN_NOT_ALLOWED`
- `PAYMENT_ALREADY_RECORDED`
- `PAYMENT_AMOUNT_INVALID`
- `PAYMENT_METHOD_NOT_SUPPORTED`
- `SESSION_NOT_SETTLED`

### Waitlist

- `WAITLIST_ENTRY_NOT_FOUND`
- `WAITLIST_ENTRY_ALREADY_EXISTS`
- `WAITLIST_INVALID_STATUS`
- `WAITLIST_LOCATION_REQUIRED`
- `WAITLIST_DISTANCE_EXCEEDED`

### General

- `VALIDATION_ERROR`
- `RESOURCE_CONFLICT`
- `RATE_LIMIT_EXCEEDED`
- `IDEMPOTENCY_CONFLICT`
- `INTERNAL_ERROR`

These codes are a starting catalog. Add operation-specific codes as implementation requires, without exposing internal database errors.

---

## 7. Authentication and Authorization

### 7.1 Authenticated Applications

Staff authentication uses Supabase Auth.

Customer authentication for the waitlist application also uses Supabase Auth.

Each authenticated user has an associated application profile and relevant organization or customer relationships.

The backend obtains the authenticated identity from the verified Supabase JWT/session.

### 7.2 Organization Isolation

Every organization-owned operation must validate organization membership.

Every branch-scoped operation must validate branch assignment and permission.

The backend must prevent:

- Cross-organization data access.
- Unauthorized branch access.
- Access through forged organization IDs.
- Access through forged branch IDs.
- Unauthorized role assignment.
- Unauthorized subscription changes.

RLS is mandatory for exposed business tables.

RPCs and Edge Functions must independently enforce the authorization rules appropriate to their execution context.

### 7.3 Role Model

The organization uses five fixed roles:

- Owner
- Admin
- Manager
- Cashier
- Kitchen Staff

Users may have multiple roles. Effective permissions are combined but remain limited by assigned branch scope.

Owner has organization-wide authority.

Admin may be organization-wide or branch-assigned according to their configured scope.

Manager, Cashier, and Kitchen Staff are restricted to assigned branches.

The backend must use centralized permission definitions rather than scattered frontend role checks.

Only the Owner may initiate subscription renewal, upgrades, downgrades, or plan changes.

Admin may manage permitted subscription contact information.

### 7.4 Platform Admin

Platform Admin is separate from organization roles.

Platform Admin operations must use dedicated authorization checks.

Platform Admin does not automatically receive access to restaurant business data.

Exceptional access to organization data requires explicit, time-limited authorization and mandatory audit logging.

---

## 8. Operation-to-Backend Mechanism Matrix

This section defines the recommended implementation mechanism for each major operation.

The matrix is authoritative for initial implementation planning. Individual RPC and Edge Function names may be adjusted during implementation, but their responsibilities must remain consistent with this document.

### 8.1 POS — Organization and Branch Management

| Operation                       | Mechanism               | Backend responsibility                                                                      |
| ------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------- |
| Register organization           | RPC                     | Create organization, initial branch, owner profile, and required initial records atomically |
| View organization profile       | Direct query            | RLS-protected organization read                                                             |
| Update organization profile     | RPC                     | Validate ownership/permission and update organization                                       |
| View branch list                | Direct query            | Return only branches accessible to the authenticated user                                   |
| View branch details             | Direct query            | Enforce organization and branch scope                                                       |
| Create branch                   | RPC                     | Validate organization entitlement, branch limit, and permission                             |
| Update branch                   | RPC                     | Validate branch scope and update allowed fields                                             |
| Deactivate branch               | RPC                     | Validate business constraints and preserve historical data                                  |
| Switch active branch            | Frontend + direct query | Frontend changes context; every subsequent backend request revalidates access               |
| View branch settings            | Direct query            | RLS-protected settings read                                                                 |
| Update branch settings          | RPC                     | Validate permissions and update settings                                                    |
| View subscription information   | Direct query or RPC     | Return authorized subscription information                                                  |
| Manage subscription contact     | RPC                     | Allow Owner/Admin according to contact-management permissions                               |
| Initiate plan change or renewal | RPC or Edge Function    | Owner-only request; actual billing integration is a later workflow                          |

Organization registration must be atomic. A partially created organization without its initial branch and owner must not be left behind.

Branch creation must enforce subscription entitlements server-side.

A restricted organization cannot create or modify branches.

### 8.2 POS — Staff Management

| Operation            | Mechanism           | Backend responsibility                                                          |
| -------------------- | ------------------- | ------------------------------------------------------------------------------- |
| View staff list      | Direct query        | Enforce organization and branch visibility                                      |
| View staff profile   | Direct query        | Validate staff visibility                                                       |
| Invite staff         | Edge Function + RPC | Trusted invitation workflow and database membership creation                    |
| Create staff account | Edge Function + RPC | Coordinate Auth identity and organization membership                            |
| Update staff profile | RPC                 | Validate permissions and update allowed fields                                  |
| Assign roles         | RPC                 | Validate assignable roles and actor permissions                                 |
| Assign branches      | RPC                 | Validate organization membership and branch scope                               |
| Deactivate staff     | RPC                 | Revoke or restrict organization access without destroying historical references |
| Reactivate staff     | RPC                 | Restore access after permission and account checks                              |

Staff invitations may use Supabase Auth invitation functionality through a trusted server-side workflow.

Never allow a frontend to assign itself Owner, Admin, or Platform Admin privileges.

Role and branch assignment changes must be audited.

### 8.3 POS — Menu Management

| Operation                         | Mechanism    | Backend responsibility                                   |
| --------------------------------- | ------------ | -------------------------------------------------------- |
| View menu categories              | Direct query | RLS-protected organization menu read                     |
| View menu items                   | Direct query | RLS-protected menu read                                  |
| Create category                   | RPC          | Validate permission and create category                  |
| Update category                   | RPC          | Validate ownership and update category                   |
| Delete/archive category           | RPC          | Validate dependencies and preserve historical references |
| Create menu item                  | RPC          | Validate fields and create item                          |
| Update menu item                  | RPC          | Validate permission and update base item information     |
| Archive menu item                 | RPC          | Preserve historical order references                     |
| Create modifier group             | RPC          | Validate group configuration                             |
| Update modifier group             | RPC          | Validate modifier rules and dependencies                 |
| Assign modifier group to item     | RPC          | Validate item/group ownership                            |
| Configure branch availability     | RPC          | Validate branch scope and update availability            |
| Configure organization base price | RPC          | Update organization-level price                          |
| Configure branch price override   | RPC          | Validate branch and item relationship                    |
| Remove branch price override      | RPC          | Restore inheritance of current organization base price   |
| View branch menu                  | Direct query | Return available items with effective branch pricing     |

Pricing rules:

- Organization owns base menu pricing.
- Branches inherit organization base prices unless an override exists.
- Updating a base price affects branches without overrides.
- Removing an override restores inheritance of the current base price.
- Order submission snapshots the effective price at submission time.
- Historical orders must not change when menu prices change.

Modifier selections must be validated by the backend, including selection limits and availability.

### 8.4 POS — Table Management

| Operation                  | Mechanism                                 | Backend responsibility                                                |
| -------------------------- | ----------------------------------------- | --------------------------------------------------------------------- |
| View tables                | Direct query                              | Return branch-scoped tables                                           |
| Create table               | RPC                                       | Validate permission and create table                                  |
| Update table               | RPC                                       | Validate branch ownership                                             |
| Deactivate table           | RPC                                       | Prevent invalid deactivation while an active session exists           |
| View table status          | Direct query                              | Return current operational status                                     |
| Generate table QR          | Edge Function or trusted server operation | Generate QR payload referencing the permanent table identifier        |
| Regenerate table QR        | Edge Function or trusted server operation | Replace QR identifier and invalidate the old identifier if applicable |
| View active dining session | Direct query                              | Return authorized active session information                          |

Table QR codes are permanent reusable table locators, not guest authentication credentials.

A table may have only one active dining session at a time.

Closing the session releases the table for a future session.

### 8.5 POS — Orders and KDS

| Operation                      | Mechanism               | Backend responsibility                            |
| ------------------------------ | ----------------------- | ------------------------------------------------- |
| View incoming orders           | Direct query + Realtime | Return branch-authorized orders                   |
| View order details             | Direct query            | Validate branch access                            |
| Accept order                   | RPC                     | Validate current state and transition             |
| Reject order                   | RPC                     | Validate permission and transition, record reason |
| Update item preparation status | RPC                     | Enforce valid item-level transitions              |
| Mark item served               | RPC                     | Validate preparation state and permissions        |
| Mark order served              | RPC                     | Validate all non-cancelled items are served       |
| Cancel order                   | RPC                     | Validate cancellation rules and record reason     |
| Cancel individual item         | RPC                     | Validate preparation state and permissions        |
| Correct order                  | RPC                     | Apply explicit audited correction workflow        |
| Subscribe to order updates     | Realtime                | Deliver authorized order changes                  |
| Subscribe to KDS updates       | Realtime                | Deliver authorized preparation changes            |

Order lifecycle:

`Pending → Accepted → Preparing → Ready → Served`

Cancellation is a separate terminal outcome where permitted.

The backend enforces all transitions.

Item preparation statuses are tracked independently.

An order is considered served when all non-cancelled items are served.

Payment status is independent of order preparation status.

Orders and items must not be silently overwritten after submission.

Corrections and cancellations require appropriate permissions and audit records.

### 8.6 POS — Billing and Payments

| Operation                   | Mechanism    | Backend responsibility                                              |
| --------------------------- | ------------ | ------------------------------------------------------------------- |
| Preview bill                | RPC          | Calculate current session charges using current applicable settings |
| Configure tax               | RPC          | Validate permissions and update organization/branch configuration   |
| Configure service charge    | RPC          | Validate permissions and update organization/branch configuration   |
| Apply discount              | RPC          | Validate discount type, permission, and audit details               |
| Remove discount             | RPC          | Validate permission and update bill calculation                     |
| Finalize bill               | RPC          | Calculate and freeze final bill atomically                          |
| Reopen unpaid bill          | RPC          | Validate permissions and audit reason                               |
| Void or replace unpaid bill | RPC          | Perform audited correction workflow                                 |
| View finalized bill         | Direct query | Return immutable finalized values                                   |
| Record cash payment         | RPC          | Validate full outstanding amount and record payment atomically      |
| Calculate change            | RPC          | Calculate change using authoritative payment values                 |
| View payment history        | Direct query | Return authorized payment records                                   |
| Close dining session        | RPC          | Close only after successful full settlement                         |

Billing rules:

- One consolidated bill per dining session.
- Initial release supports one full-settlement cash payment.
- Split bills and partial payments are not supported initially.
- Payment records remain separate from dining session records.
- The data model should remain extensible for future payment workflows.
- Bill preview uses current applicable tax, service charge, and discount settings.
- Finalization freezes the bill.
- A finalized bill is immutable.
- An unpaid bill may only be reopened or voided/replaced through an audited action.
- The dining session closes only after the full bill is successfully settled.

Initial payment support is cash-only.

Subscription billing is a separate system and must not be confused with restaurant customer order payments.

The exact tax base, discount application order, and rounding policy must follow the approved data model and billing rules. Do not invent alternative calculation behavior in frontend code.

### 8.7 Ordering — Public Guest Operations

| Operation                        | Mechanism                                              | Backend responsibility                                                 |
| -------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------- |
| Resolve table QR                 | Edge Function                                          | Validate public table identifier and resolve branch/table              |
| Establish guest session          | Edge Function + RPC                                    | Find or atomically create active dining session and issue device token |
| Retrieve branch information      | Direct query or Edge Function                          | Return public-safe branch information                                  |
| Retrieve menu                    | Direct query                                           | Return public menu and effective branch prices                         |
| Retrieve menu item details       | Direct query                                           | Return available item and modifier information                         |
| Submit guest order               | Edge Function + RPC                                    | Validate token, session, menu, prices, and create order atomically     |
| Retrieve session orders          | Edge Function or approved token-aware query            | Validate guest token and return session-scoped orders                  |
| Retrieve order status            | Edge Function or approved token-aware query            | Validate guest token and return authorized status                      |
| Reconnect device                 | Edge Function                                          | Validate device token and restore guest session access                 |
| Subscribe to guest order updates | Authorized Realtime or Edge Function-mediated delivery | Deliver only session-authorized updates                                |

#### Guest Session Security

Guest ordering does not require customer login or registration.

Do not create Supabase Auth anonymous users for each table or device.

The guest session system uses custom device tokens.

Rules:

1. Table QR identifies a restaurant, branch, and table.
2. Table QR does not directly grant access to an active dining session.
3. Backend resolves the current active dining session.
4. If no active session exists, backend may atomically create one.
5. Concurrent scans must not create multiple active sessions for the same table.
6. Each device receives its own random guest token.
7. Raw guest tokens are returned only through trusted server-side operations.
8. Only token hashes are stored server-side.
9. Tokens are scoped to a dining session and device.
10. Tokens expire or become invalid when the dining session closes.
11. Subsequent guest operations require a valid device token.
12. Guest tokens must never grant access to another dining session or table.
13. The service-role key must never be exposed to the browser.

Guest token hashes and sensitive token metadata should be stored in the non-exposed private schema.

Guest requests must validate:

- Token validity.
- Token expiry and revocation.
- Session ownership.
- Session status.
- Branch and table relationship.
- Organization subscription restrictions.
- Order contents and menu availability.

#### Restricted Subscription Behavior

When an organization enters restricted subscription status:

- Existing sessions may be viewed and completed.
- Existing orders may continue through preparation and service.
- Existing bills may be finalized and settled.
- New dining sessions cannot be created.
- New orders cannot be submitted, including additional orders to an existing session.

An existing session must not be treated as permission to create new orders while the organization is restricted.

### 8.8 Waitlist — Customer Accounts

| Operation                    | Mechanism                        | Backend responsibility                             |
| ---------------------------- | -------------------------------- | -------------------------------------------------- |
| Register customer            | Supabase Auth + profile creation | Create customer identity and profile               |
| Login customer               | Supabase Auth                    | Authenticate customer                              |
| View customer profile        | Direct query                     | Return own profile                                 |
| Update customer profile      | RPC or RLS-protected update      | Validate permitted fields                          |
| View active waitlist entries | Direct query                     | Return entries belonging to authenticated customer |
| View waitlist history        | Direct query                     | Return customer-owned historical entries           |

Customer accounts are universal across participating restaurants.

A customer account is not tied to one organization.

### 8.9 Waitlist — Customer Operations

| Operation                   | Mechanism                             | Backend responsibility                                               |
| --------------------------- | ------------------------------------- | -------------------------------------------------------------------- |
| Resolve waitlist QR         | Edge Function or direct public lookup | Identify branch and waitlist configuration                           |
| Join waitlist               | RPC or Edge Function + RPC            | Validate branch, customer, location rules, and uniqueness            |
| View queue entry            | Direct query                          | Enforce customer ownership                                           |
| Cancel own entry            | RPC                                   | Validate ownership and current state                                 |
| View estimated position     | RPC or approved query                 | Calculate position without exposing unnecessary customer information |
| Request location permission | Frontend                              | Request location only when branch configuration requires it          |
| Validate geolocation        | RPC or Edge Function                  | Calculate distance using branch coordinates and configured radius    |

Waitlist rules:

- A customer may have active entries at multiple restaurants simultaneously.
- A customer may have only one active entry per branch.
- Queue ordering is FIFO by default.
- Staff may manually reorder entries through an audited operation.
- Geolocation is optional and branch-configurable.
- Location is requested when joining, not continuously.
- The backend calculates distance using branch coordinates and configured radius.
- Geolocation is a presence signal, not proof of physical presence.
- GPS spoofing must be considered.
- Precise coordinates should not be retained longer than necessary.

### 8.10 Waitlist — POS Queue Management

| Operation                   | Mechanism               | Backend responsibility                           |
| --------------------------- | ----------------------- | ------------------------------------------------ |
| View queue                  | Direct query + Realtime | Return branch-scoped queue                       |
| Add walk-in                 | RPC                     | Create staff-created queue entry                 |
| Update customer information | RPC                     | Validate permissions and update permitted fields |
| Notify customer             | Edge Function           | Trigger configured notification delivery         |
| Update queue status         | RPC                     | Validate allowed state transition                |
| Seat customer               | RPC                     | Validate status and update queue entry           |
| Cancel entry                | RPC                     | Validate permission and record reason            |
| Mark no-show                | RPC                     | Validate status and record action                |
| Reorder queue               | RPC                     | Apply audited manual reorder                     |
| Subscribe to queue updates  | Realtime                | Deliver authorized branch queue changes          |

Waitlist statuses:

- Waiting
- Notified
- Seated
- Cancelled
- No-show

The backend must enforce valid status transitions and prevent duplicate active entries.

### 8.11 POS — Reports and Analytics

| Operation                | Mechanism                                      | Backend responsibility                         |
| ------------------------ | ---------------------------------------------- | ---------------------------------------------- |
| View sales summary       | RPC or direct query                            | Return authorized aggregated sales data        |
| View order summary       | RPC or direct query                            | Aggregate order information                    |
| View popular menu items  | RPC                                            | Calculate item popularity for authorized scope |
| View payment summary     | RPC or direct query                            | Aggregate payment records                      |
| View staff activity      | RPC                                            | Return authorized staff activity information   |
| View branch report       | RPC or direct query                            | Enforce branch permissions                     |
| View organization report | RPC                                            | Enforce organization-wide permissions          |
| Export report            | Edge Function when file generation is required | Generate trusted report export                 |

Reports must respect the user's organization and branch scope.

Organization-wide reports require organization-wide permission.

Branch-assigned users must not receive data from unassigned branches.

Report calculations must use authoritative stored transaction data.

### 8.12 Historical Data

| Operation                    | Mechanism           | Backend responsibility                 |
| ---------------------------- | ------------------- | -------------------------------------- |
| Retrieve historical orders   | Direct query        | Enforce scope and pagination           |
| Retrieve historical bills    | Direct query        | Enforce scope and pagination           |
| Retrieve historical payments | Direct query        | Enforce scope and pagination           |
| Retrieve waitlist history    | Direct query        | Enforce customer or staff access scope |
| Retrieve audit history       | Direct query or RPC | Enforce authorized audit visibility    |

Historical data operations must support standardized filtering, sorting, and pagination.

Historical orders and settled payments must remain preserved.

### 8.13 Subscription Management

| Operation                    | Mechanism                                 | Backend responsibility                                   |
| ---------------------------- | ----------------------------------------- | -------------------------------------------------------- |
| View subscription status     | Direct query or RPC                       | Return authorized plan and lifecycle information         |
| View branch limits and usage | RPC or direct query                       | Return entitlement information                           |
| View renewal instructions    | Direct query or Edge Function             | Return configured renewal information                    |
| Update subscription contact  | RPC                                       | Permit Owner/Admin according to defined permissions      |
| Initiate renewal             | RPC or Edge Function                      | Owner-only renewal request                               |
| Upgrade plan                 | RPC or Edge Function                      | Owner-only plan change request                           |
| Downgrade plan               | RPC or Edge Function                      | Owner-only plan change request                           |
| Enforce restricted status    | Database functions and backend validation | Block prohibited operations                              |
| Restore access after renewal | Trusted backend workflow                  | Revalidate subscription and restore permitted operations |

Subscription lifecycle:

1. Active.
2. Expired.
3. Grace period.
4. Restricted after grace period.
5. Renewed and restored.

Free organizations are permanent and do not expire.

Restricted organizations retain access to historical information and may complete existing dining sessions.

New operational activities and organization administration are blocked, except permitted subscription-management operations.

Only Owner may initiate renewal, upgrade, downgrade, or plan changes.

The actual subscription billing provider and payment workflow are outside the initial restaurant cash-payment implementation and must be specified separately.

### 8.14 Organization Deletion

| Operation                     | Mechanism                                      | Backend responsibility                               |
| ----------------------------- | ---------------------------------------------- | ---------------------------------------------------- |
| Request organization deletion | RPC                                            | Validate Owner permission and schedule soft deletion |
| View deletion status          | Direct query                                   | Return authorized status                             |
| Cancel pending deletion       | RPC                                            | Validate Owner permission and retention period       |
| Permanent deletion            | Scheduled Edge Function or trusted backend job | Perform retention-aware cleanup                      |

Deletion rules:

- Organization deletion is soft deletion initially.
- Initial retention period is 30 days and configurable.
- Pending deletion disables new operational activities.
- Owner may cancel deletion during the retention period.
- Permanent deletion occurs after retention, subject to legal, backup, and data-retention requirements.
- Historical and audit data must be handled according to retention policy.
- Outstanding sessions, payments, subscriptions, and dependencies must be considered.
- Supabase Auth identities must not be deleted automatically if they have other dependencies.

### 8.15 Platform Admin

| Operation                               | Mechanism                   | Backend responsibility                               |
| --------------------------------------- | --------------------------- | ---------------------------------------------------- |
| List organizations                      | RPC                         | Platform Admin-only organization listing             |
| View organization metadata              | RPC                         | Return authorized platform-level information         |
| Suspend organization                    | RPC                         | Validate Platform Admin permission and record reason |
| Reactivate organization                 | RPC                         | Validate permission and restore status               |
| Manage plans                            | RPC                         | Create/update platform plans                         |
| Manage entitlements                     | RPC                         | Update plan limits and capabilities                  |
| Manage platform settings                | RPC                         | Validate Platform Admin permission                   |
| View platform audit logs                | Direct query or RPC         | Return platform-level audit records                  |
| Request exceptional organization access | RPC                         | Create explicit, scoped, time-limited access grant   |
| Revoke exceptional access               | RPC                         | Revoke access and record audit event                 |
| Access exceptional organization data    | RLS-aware trusted operation | Verify active grant, scope, and expiry               |

Platform Admin must not automatically receive unrestricted access to restaurant business data.

Exceptional access must specify:

- Target organization.
- Requested scope.
- Reason.
- Authorizing actor.
- Start time.
- Expiration time.
- Revocation status.

All exceptional access must be auditable.

---

## 9. RPC Design Principles

### 9.1 RPC Responsibilities

RPCs should be used for operations that require authoritative database execution.

Each RPC should have:

- A single clearly defined responsibility.
- Explicit request parameters.
- Explicit return type.
- Authorization checks.
- Business-rule validation.
- Transaction-safe execution.
- Appropriate error codes.
- Audit logging where required.

Avoid creating generic RPCs that allow arbitrary table updates or arbitrary SQL-like behavior.

### 9.2 Recommended RPC Groups

The following are suggested responsibility groups, not a requirement to create every function immediately.

#### Organization

- `register_organization`
- `update_organization`
- `create_branch`
- `update_branch`
- `deactivate_branch`
- `update_branch_settings`

#### Staff

- `create_staff_membership`
- `update_staff_profile`
- `assign_staff_roles`
- `assign_staff_branches`
- `deactivate_staff`
- `reactivate_staff`

#### Menu

- `create_menu_category`
- `update_menu_category`
- `archive_menu_category`
- `create_menu_item`
- `update_menu_item`
- `archive_menu_item`
- `create_modifier_group`
- `update_modifier_group`
- `assign_modifier_group`
- `update_branch_item_availability`
- `update_base_item_price`
- `set_branch_price_override`
- `remove_branch_price_override`

#### Tables and Dining Sessions

- `create_table`
- `update_table`
- `deactivate_table`
- `resolve_or_create_dining_session`

#### Orders

- `submit_order`
- `accept_order`
- `reject_order`
- `update_order_item_status`
- `cancel_order`
- `cancel_order_item`
- `mark_order_served`
- `correct_order`

#### Billing and Payments

- `preview_bill`
- `apply_bill_discount`
- `remove_bill_discount`
- `finalize_bill`
- `reopen_unpaid_bill`
- `void_or_replace_unpaid_bill`
- `record_cash_payment`
- `close_settled_dining_session`

#### Waitlist

- `join_waitlist`
- `add_walk_in`
- `update_waitlist_status`
- `reorder_waitlist`
- `cancel_waitlist_entry`
- `calculate_waitlist_position`

#### Subscription and Platform

- `update_subscription_contact`
- `request_subscription_renewal`
- `request_plan_change`
- `request_organization_deletion`
- `cancel_organization_deletion`
- `suspend_organization`
- `reactivate_organization`
- `manage_plan_entitlements`
- `request_exceptional_access`
- `revoke_exceptional_access`

Function names may be refined during implementation. The important requirement is that the operation boundaries remain explicit and secure.

### 9.3 Transaction Boundaries

The following workflows must be atomic:

**Organization registration**

- Create organization.
- Create initial branch.
- Create owner profile and membership.
- Create required initial configuration.

**Dining session creation**

- Resolve table.
- Check for an active session.
- Create a session only if none exists.
- Prevent concurrent duplicate active sessions.

**Order submission**

- Validate guest/staff authorization.
- Validate session status.
- Validate subscription restrictions.
- Validate menu item and modifier availability.
- Calculate effective prices.
- Snapshot order item details and prices.
- Create order and order items.

**Bill finalization**

- Validate session and orders.
- Calculate authoritative totals.
- Apply current applicable settings.
- Freeze bill values.
- Prevent duplicate finalization.

**Cash payment**

- Validate finalized bill.
- Validate outstanding amount.
- Record full cash settlement.
- Calculate change.
- Update payment and session settlement state consistently.

**Waitlist join**

- Validate customer and branch.
- Validate optional location requirements.
- Enforce one active entry per customer per branch.
- Create queue entry.

**Queue reorder**

- Validate permission.
- Apply new position.
- Record actor and reason.

Database transactions must prevent partial execution of these workflows.

---

## 10. Edge Function Design Principles

### 10.1 Responsibilities

Edge Functions are responsible for trusted orchestration and external-facing workflows.

They must not be used merely as a proxy for every direct database read.

Use them when an operation requires:

- Secrets unavailable to clients.
- External API calls.
- Trusted token handling.
- Complex orchestration.
- Scheduled execution.
- Notification delivery.
- File processing.

### 10.2 Suggested Edge Function Groups

Potential initial functions:

```text
functions/
├── staff-invite/
├── guest-resolve-table/
├── guest-reconnect/
├── guest-submit-order/
├── guest-session-data/
├── customer-notify/
├── report-export/
├── organization-retention-cleanup/
├── subscription-workflow/
└── platform-exceptional-access/
```

This is a suggested organization. Related operations may share an Edge Function when the API boundary remains clear.

### 10.3 Service Role Security

The Supabase service-role key must never be exposed to frontend applications.

Edge Functions may use privileged credentials only when necessary.

When using privileged access:

- Authenticate the incoming request.
- Validate the caller's identity.
- Verify organization and branch scope.
- Verify required permissions.
- Validate all inputs.
- Apply business rules.
- Log sensitive administrative actions.
- Return only authorized information.

A privileged database client does not automatically make an operation authorized.

---

## 11. Idempotency and Retry Safety

### 11.1 Purpose

Operations that may be retried due to network failures or repeated user actions must support idempotency.

The backend must prevent duplicate business records when the same logical request is submitted more than once.

### 11.2 Required Operations

Idempotency should be implemented for at least:

- Guest order submission.
- Staff order creation where retries may occur.
- Cash payment recording.
- Organization registration.
- Waitlist joining.
- Guest session creation.
- Subscription renewal requests.
- Other operations where duplicate execution would create financial or operational consequences.

### 11.3 Idempotency Key Behavior

The client or trusted backend generates a unique key for a logical operation.

The backend stores enough information to identify:

- The key.
- The operation type.
- The authenticated user or guest session context.
- The request fingerprint.
- The operation result.
- The execution status.
- The creation timestamp.

Rules:

1. Repeating the same key with the same logical request returns the original result.
2. Reusing the same key with a different request payload returns `IDEMPOTENCY_CONFLICT`.
3. Concurrent requests with the same key must not create duplicate records.
4. Failed operations must not be incorrectly reported as successful.
5. Retention and cleanup must follow a defined backend policy.

Do not rely on frontend button disabling as the only duplicate-prevention mechanism.

---

## 12. Realtime Architecture

### 12.1 Purpose

Supabase Realtime provides live updates for operational interfaces.

It supplements normal database reads and mutations; it does not replace authoritative backend validation.

### 12.2 Realtime Use Cases

| Event category                  | Subscribers                      |
| ------------------------------- | -------------------------------- |
| New order                       | POS order dashboard, KDS         |
| Order status changed            | POS, Ordering                    |
| Item preparation status changed | POS, KDS, Ordering               |
| Order served                    | POS, Ordering                    |
| Waitlist entry created          | POS queue                        |
| Waitlist status changed         | POS queue, customer Waitlist app |
| Waitlist position changed       | POS queue, customer Waitlist app |
| Dining session status changed   | POS, authorized Ordering clients |
| Branch operational updates      | Authorized POS clients           |

### 12.3 Authorization

Realtime subscriptions must be restricted by:

- Organization.
- Branch.
- Authenticated user.
- Assigned roles.
- Resource ownership where applicable.

Guest clients must not receive organization-wide or branch-wide staff data.

Guest subscriptions must be scoped to their authorized dining session.

Customer waitlist subscriptions must be scoped to the customer's own entries.

### 12.4 Reconnection

Clients must handle:

- Temporary network disconnection.
- Subscription expiration.
- Reconnection.
- Duplicate events.
- Out-of-order events.
- Missed updates.

Realtime events should be treated as notifications that data changed.

When consistency is uncertain, the frontend should retrieve the latest authoritative record.

### 12.5 Event Payloads

Do not expose unnecessary business data through Realtime.

Prefer minimal event payloads containing identifiers and relevant state changes.

Clients can retrieve full authorized records through the appropriate query or API.

---

## 13. Customer Notifications

### 13.1 Architecture

Customer notifications must be initiated by trusted backend operations.

The frontend may request or trigger a business action, but it must not directly use provider credentials.

An Edge Function or trusted notification service handles delivery.

### 13.2 Notification Events

Potential notification events include:

- Waitlist entry confirmation.
- Waitlist position updates where appropriate.
- Customer turn approaching.
- Customer called or notified.
- Waitlist cancellation.
- Other customer-facing operational notifications.

### 13.3 Delivery Channels

The notification architecture should support configurable channels:

- Email.
- SMS.
- WhatsApp.

Actual providers and delivery integrations may be implemented incrementally.

The backend should maintain a provider-independent notification interface so providers can be changed without redesigning application workflows.

### 13.4 Delivery Reliability

The notification system should account for:

- Delivery failures.
- Retry policies.
- Duplicate notifications.
- Provider rate limits.
- Delivery status.
- Customer communication preferences.
- Auditability of notification attempts.

Notification delivery must not silently change the underlying waitlist or order state.

For example, a failed notification must not automatically mark a customer as seated.

---

## 14. Pagination, Sorting, and Filtering

### 14.1 General Rules

Collection endpoints and queries must support consistent pagination.

Recommended default page size: 20 records.

Recommended maximum page size: 100 records.

The backend must validate pagination parameters.

### 14.2 Pagination

Use cursor-based pagination for large or frequently changing collections where appropriate.

Offset pagination may be used for simpler administrative and historical views where stable ordering is available.

The chosen pagination method must be defined per operation contract.

Paginated responses should expose:

- Returned records.
- Requested page size.
- Whether more records exist.
- Next cursor or page information when applicable.

### 14.3 Sorting

Sorting must use an explicit allowlist of supported fields.

Do not accept arbitrary database column names from clients.

Always define deterministic ordering, including a stable secondary sort key when necessary.

Examples:

- Orders: creation time.
- Waitlist: queue position and creation time.
- Payments: payment time.
- Historical records: creation time or business date.

### 14.4 Filtering

Supported filters should be defined per resource.

Common filters include:

- Status.
- Branch.
- Date range.
- Search term.
- Staff member.
- Payment method.
- Category.
- Customer.

The backend must validate filter values and enforce authorization independently.

### 14.5 Date and Time

Use UTC timestamps for stored instants.

Branch-local date filtering must use the branch's configured IANA timezone.

For example:

`Asia/Jakarta`

Date-range queries must have clearly defined inclusive/exclusive boundaries to prevent missing or duplicated records between consecutive periods.

---

## 15. Rate Limiting and Abuse Prevention

### 15.1 Protected Operations

Configurable backend-enforced rate limits must apply to:

- Public guest endpoints.
- Guest token issuance and reconnection.
- Guest order submission.
- Authentication-related operations.
- Customer registration.
- Waitlist joining.
- Sensitive administrative mutations.
- Notification-triggering operations.

### 15.2 Rate Limit Principles

Rate limits should consider relevant identity and context, such as:

- IP address.
- Authenticated user.
- Guest token.
- Organization.
- Branch.
- Operation type.

Avoid relying exclusively on IP addresses because multiple legitimate users may share an IP.

### 15.3 Enforcement

Rate limits must be enforced at trusted backend boundaries.

Frontend throttling may improve user experience but is not a security control.

Rate-limit violations should return:

`RATE_LIMIT_EXCEEDED`

Where appropriate, responses should include retry timing without exposing internal rate-limit implementation details.

### 15.4 Guest Abuse Prevention

Guest endpoints must validate:

- QR identifier.
- Guest token.
- Session status.
- Request size.
- Menu and modifier selections.
- Order submission frequency.
- Idempotency key.
- Subscription restrictions.

Do not allow public endpoints to access arbitrary organization data.

---

## 16. Audit Logging

The backend must record sensitive business and administrative operations.

Audit-worthy actions include:

- Organization profile changes.
- Branch creation and deactivation.
- Staff role changes.
- Branch assignment changes.
- Menu price changes.
- Branch price overrides.
- Order cancellation and correction.
- Item cancellation.
- Discount application.
- Bill reopening.
- Bill voiding or replacement.
- Payment events and corrections.
- Waitlist manual reorder.
- Subscription changes.
- Organization suspension/reactivation.
- Organization deletion requests and cancellations.
- Platform Admin actions.
- Exceptional organization access.
- Sensitive configuration changes.

Audit records should identify:

- Actor.
- Organization context.
- Branch context when relevant.
- Action.
- Target resource.
- Timestamp.
- Reason where required.
- Relevant before/after metadata where appropriate.

Audit records must not expose credentials, raw guest tokens, or unnecessary sensitive information.

Audit records must not be silently modified or deleted through normal application operations.

---

## 17. Subscription Enforcement

Subscription restrictions must be enforced by the backend.

Frontend UI restrictions are supplementary only.

### 17.1 Active Organization

Normal authorized operations are permitted.

### 17.2 Expired and Grace Period

Normal operations continue during the configured grace period.

The backend should expose status information so the frontend can display renewal warnings.

### 17.3 Restricted Organization

The backend blocks:

- New orders.
- New dining sessions.
- New branches.
- Organization administration.
- Staff and role administration.
- Menu and table administration.
- Other prohibited operational mutations.

The backend continues to permit:

- Historical data retrieval.
- Existing order preparation and service.
- Existing bill finalization.
- Full settlement of existing sessions.
- Authorized subscription information retrieval.
- Permitted subscription contact management.
- Owner-only renewal and plan-change workflows.

The exact operation allowlist must be centralized so restrictions are applied consistently across POS, Ordering, and Waitlist.

### 17.4 Free Organization

Free organizations do not expire and are not subject to the subscription expiration lifecycle.

Their branch limit is enforced when creating additional branches.

---

## 18. Data Consistency and Historical Integrity

### 18.1 Order Snapshots

Order items must retain the applicable item name, selected modifiers, prices, and other relevant details at the time of submission.

Later menu changes must not modify historical orders.

### 18.2 Billing Snapshots

Finalized bills must preserve the calculated values and applicable configuration used at finalization.

Later tax, service charge, or discount configuration changes must not modify finalized bills.

### 18.3 Payment Records

Payment records must be stored separately from dining sessions and bills.

Initial release supports full cash settlement only.

Payment correction, void, refund, and reconciliation workflows require explicit audited operations and must not be implemented as silent edits.

### 18.4 Historical Data

Completed orders, settled payments, and audit records must remain available according to retention policies.

Deletion and archival must preserve required historical relationships and legal obligations.

---

## 19. Security Requirements

All implementations must follow these requirements:

1. Never expose the Supabase service-role key to frontend code.
2. Enable RLS on exposed business tables.
3. Validate organization and branch membership server-side.
4. Derive authenticated identity from verified authentication context.
5. Never trust client-supplied roles or permissions.
6. Validate all untrusted input.
7. Use narrowly scoped RPCs.
8. Protect sensitive operations with appropriate authorization checks.
9. Store guest token hashes, never raw tokens.
10. Restrict guest access to the authorized dining session.
11. Enforce subscription restrictions server-side.
12. Use idempotency for retry-sensitive mutations.
13. Audit sensitive administrative and financial actions.
14. Apply rate limits to public and sensitive endpoints.
15. Avoid exposing internal errors and sensitive metadata.
16. Restrict Realtime subscriptions to authorized data.
17. Validate external webhook authenticity when integrations are introduced.
18. Keep secrets in trusted server-side configuration.

Security requirements in this document must be implemented alongside the database RLS and security specifications.

---

## 20. Testing Requirements

The backend implementation must include tests for critical API and RPC behavior.

### 20.1 Authorization Tests

Test:

- User accessing their own organization.
- User attempting to access another organization.
- Staff accessing assigned branches.
- Staff attempting to access unassigned branches.
- Unauthorized role assignment.
- Owner-only subscription operations.
- Platform Admin operations.
- Exceptional access expiration and revocation.

### 20.2 Transaction Tests

Test:

- Organization registration rollback.
- Concurrent dining session creation.
- Duplicate order submission.
- Invalid menu item submission.
- Invalid modifier selection.
- Concurrent order state transitions.
- Bill finalization consistency.
- Duplicate cash payment requests.
- Invalid payment amount.
- Closing a session before settlement.
- Duplicate active waitlist entries.
- Concurrent waitlist joins.

### 20.3 Subscription Tests

Test:

- Active organization operations.
- Grace-period operations.
- Restricted organization behavior.
- Existing session completion.
- New order rejection during restriction.
- New session rejection during restriction.
- Subscription renewal restoring access.
- Free organization remaining unrestricted by expiration.

### 20.4 Guest Security Tests

Test:

- Invalid QR identifiers.
- Expired guest tokens.
- Revoked guest tokens.
- Tokens used with another session.
- Tokens used after session closure.
- Concurrent guest session creation.
- Unauthorized guest order retrieval.
- Rate-limit enforcement.
- Guest ordering during restricted subscription status.

### 20.5 Historical Integrity Tests

Test:

- Menu price changes do not modify submitted orders.
- Menu archival does not remove historical order details.
- Finalized bills remain unchanged after configuration updates.
- Settled payment records cannot be silently overwritten.
- Audit records are preserved.

---

## 21. Implementation Guidelines for OpenCode Agents

All coding agents working on this platform must follow these rules.

### 21.1 Source of Truth

The `restaurant-platform-backend` repository is the canonical source for:

- Database schema.
- Migrations.
- RLS policies.
- RPCs.
- Edge Functions.
- Shared types.
- Runtime validation schemas.
- Error codes.
- API contracts.
- Backend business rules.

Do not independently redefine these contracts in frontend repositories.

### 21.2 Before Implementing an Operation

Agents must:

1. Inspect the relevant architecture and data model documentation.
2. Locate the corresponding shared API contract.
3. Identify the required authorization rules.
4. Identify the transaction and idempotency requirements.
5. Determine whether the operation uses direct queries, RPCs, Edge Functions, or a combination.
6. Implement the backend contract before integrating dependent frontend behavior.

If an operation is not documented, do not invent a conflicting business rule.

Document the gap and request clarification when the missing decision materially affects correctness or security.

### 21.3 Frontend Integration

Frontend agents must:

- Use the canonical shared contracts.
- Call approved backend operations.
- Handle standardized errors.
- Avoid implementing authoritative business calculations locally.
- Never bypass RLS or backend authorization.
- Never expose privileged credentials.
- Handle Realtime reconnection and stale data.
- Avoid duplicating business rules across applications.

### 21.4 Migration Coordination

Database changes must be implemented in the backend repository through ordered Supabase migrations.

Never modify an already-applied migration.

Create a new migration for subsequent changes.

Coordinate schema and contract changes with dependent frontend repositories.

### 21.5 Documentation Maintenance

When an implementation changes an approved API contract:

- Update the shared contract.
- Update the relevant documentation.
- Update affected tests.
- Identify dependent applications.
- Document breaking changes.
- Coordinate rollout across repositories.

Do not silently diverge from this specification.

---

## 22. Deferred Implementation Details

The architecture and operation boundaries are established, but some lower-level implementation decisions remain intentionally deferred.

These include:

- Exact SQL function signatures and parameter types.
- Exact Edge Function request and response schemas.
- Exact RLS policy expressions and grants.
- Exact pagination cursor implementation per resource.
- Exact idempotency retention duration.
- Guest token expiry, rotation, and cleanup schedule.
- Exact notification providers and delivery policies.
- Exact rate-limit thresholds.
- Exact report aggregation definitions.
- Exact tax base, discount application order, and rounding implementation.
- Payment void, refund, correction, and reconciliation workflows.
- Subscription payment provider and billing workflow.
- Organization archival and permanent deletion policy.
- Exact Realtime publication and event configuration.

These details must be resolved during implementation planning and the relevant technical specifications.

They must not be filled with arbitrary assumptions that contradict approved business rules.

---

## 23. Final Architecture Summary

The platform uses a hybrid Supabase architecture.

| Component                   | Primary responsibility                           |
| --------------------------- | ------------------------------------------------ |
| Supabase Auth               | Staff and customer authentication                |
| PostgreSQL                  | Persistent data and authoritative business state |
| RLS                         | Tenant isolation and row-level access control    |
| Direct Supabase queries     | Safe, authorized reads                           |
| PostgreSQL RPCs             | Atomic business operations and state transitions |
| Edge Functions              | Trusted orchestration and external integrations  |
| Supabase Realtime           | Authorized live operational updates              |
| Shared TypeScript contracts | Consistent interfaces across repositories        |
| Runtime validation          | Validation of untrusted API input                |
| Audit logging               | Traceability of sensitive operations             |

The central architectural principle is:

**Frontend applications manage the user experience. The backend owns authorization, business rules, transaction integrity, and authoritative data.**

All four repositories must follow this contract to maintain consistent behavior, security, and data integrity across the platform.
