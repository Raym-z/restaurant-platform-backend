# Row Level Security (RLS)

## 1. Purpose

Define security principles for protecting tenant-owned and user-owned records through PostgreSQL Row Level Security.

## 2. Core requirements

- Enable RLS on every exposed table containing protected application data.
- Use least-privilege policies and deny access by default.
- Test policies using representative authenticated and unauthenticated roles.
- Never rely on frontend filtering for data isolation.
- Review policies whenever schema relationships or authorization rules change.
- A public table QR code is not authorization to read or mutate arbitrary session data.

## 3. Tenant isolation

The tenant hierarchy is Platform → Organization → Branch.

Policies must ensure:
- Staff can access only their single associated organization and only permitted resources within it.
- Staff branch-scoped access is limited to the branch on each branch-scoped role assignment and also requires an active branch assignment for that branch.
- A branch-scoped role at Branch 1 never authorizes reads or writes at Branch 2, even if the staff member also has a branch assignment at Branch 2.
- Revoked role assignments, revoked branch assignments, inactive staff, and inactive branches are denied.
- Organization-level access is granted only to roles designed for that scope.
- Staff cannot access a second organization by changing an organization identifier.
- Customer users can access only their own protected customer records.
- Guest ordering access is limited to the active dining session resolved by a valid guest token and to explicitly allowed public operations.

Do not trust an organization ID, branch ID, table ID, or dining-session ID supplied by the client without validating it against trusted authorization data.

## 4. Guest ordering access pattern

Guest devices do not authenticate through Supabase Auth. They present a custom per-device guest token to a trusted backend operation. The backend validates the token hash, revocation/expiry state, associated session, and active session state before performing the requested operation.

Prefer keeping guest-token validation and order submission behind narrowly scoped RPCs/Edge Functions or another trusted server boundary. Do not grant broad anonymous table access merely to make QR ordering work. If any anonymous database grants are required, they must be limited to explicitly public data and reviewed separately. The raw token must never be exposed in database logs or Realtime payloads.

Guests must not be able to:
- Read arbitrary dining sessions or session history.
- Select or submit orders to an arbitrary session ID.
- Create, close, reopen, or settle a dining session directly.
- Access staff, customer-private, payment-management, or tenant-administration records.

## 5. Policy design

For each table, document whether it is exposed to client roles, whether RLS is enabled, which roles may select/insert/update/delete, how organization/branch scope is established, which helper functions or membership relationships are used, and whether access differs for staff, customers, and guests.

Avoid broad policies such as allowing every authenticated user to access all rows or allowing anonymous users to access all rows associated with a known table identifier.

## 6. Relationship integrity

RLS is not a substitute for relational constraints. Use foreign keys, unique constraints, and other database constraints to ensure related records belong to consistent organizations and branches. An order's branch and dining session must belong to the same organization/branch; a dining session must reference its own table; a guest token must reference its associated session.

## 7. Security-definer functions

Use `SECURITY DEFINER` only when necessary and after review. When used:
- Set a safe, explicit `search_path`.
- Fully qualify referenced objects where appropriate.
- Validate caller identity, guest token, tenant scope, and resource state inside the function.
- Restrict execute grants to the narrowest roles.
- Avoid returning data beyond the caller's permitted scope.
- Test both allowed and denied paths, including anonymous callers.

Do not use privileged functions as a shortcut around RLS. Token validation must not be bypassable by supplying a session ID directly.

## 8. Service-role access

The Supabase service-role key bypasses RLS and must remain server-side. Any server operation using privileged credentials must perform explicit authentication/guest-token validation and authorization checks before accessing tenant data. Never expose service-role credentials to browser clients.

## 9. Realtime and Storage

Realtime subscriptions and Storage object access must follow equivalent tenant and ownership restrictions. Guest clients should not receive broad session-table subscriptions; expose only minimal, session-scoped information through a reviewed mechanism. A secure table policy does not automatically prove every related channel or object path is secure; test each surface independently.

## 10. Testing matrix

At minimum, test:
- Unauthenticated caller with no guest token.
- Staff from the correct organization and assigned branch.
- Staff from the same organization but an unassigned branch.
- Staff attempting to access a different organization.
- Customer accessing their own record and attempting to access another customer's record.
- Guest with a valid token for an active session.
- Guest with invalid, expired, or revoked token.
- Guest attempting to access a different session or table.
- Guest token presented after session closure.
- Concurrent QR resolution for one table.
- Server-side privileged operation with missing or invalid authorization.

Test SELECT, INSERT, UPDATE, and DELETE separately where supported. Also test RPC/Edge Function execute grants and indirect data access.

## 11. Policy maintenance

Keep policies in version-controlled migrations. Document policy intent and test coverage. When a table is added, its RLS status and policy design must be part of the same reviewed change.
