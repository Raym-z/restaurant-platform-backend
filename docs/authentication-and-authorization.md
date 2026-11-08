# Authentication and Authorization

## 1. Purpose

Define identity boundaries and access-control principles for staff, customers, and unauthenticated guest ordering across the platform.

## 2. Identity categories

### Staff identity
Staff authenticate to the POS application using Supabase Auth. Each staff account belongs to exactly one organization; cross-organization staff membership is not supported. Within that organization, a staff member may be assigned to one or multiple branches. Effective access is determined by active status, role/permissions, and branch assignments.

### Customer identity
Customers have universal platform-wide Supabase Auth accounts used by the waitlist application. Customer accounts are separate from staff authorization and do not grant POS access. Customer access is limited to their own protected records and explicitly public information.

### Guest ordering identity
Guest ordering does not create Supabase Auth users, anonymous Auth users, shadow users, or premade accounts for tables. A guest device receives a custom cryptographically secure token scoped to one active dining session. The token authorizes only approved guest operations, such as reading the public menu/order context and submitting orders to that session. It is not a general user identity.

## 3. Supabase Auth and profile separation

Supabase Auth is the intended authentication provider for registered staff and customers. Staff and customer profiles/authorization records must be modeled as distinct domains, even if they use the same Supabase Auth project. Do not infer permissions from a client-editable profile field or email address alone. Trusted backend authorization must establish the caller's identity category and permitted resources.

A staff account is associated with exactly one organization. Customer accounts are platform-wide and may interact with multiple restaurants. The final profile and mapping schema, sign-up flows, and account recovery procedures must be reviewed before implementation.

## 4. Staff authorization

Staff access is determined by:
- Authenticated Supabase Auth identity.
- Active association with exactly one organization.
- Role and granted permissions.
- Branch assignments or explicitly approved organization-wide scope.
- Resource ownership, tenant consistency, and current resource state.

Initial roles:
- Owner (organization-wide).
- Admin (organization-wide or branch-scoped).
- Manager (branch-scoped).
- Cashier (branch-scoped).
- Kitchen Staff (branch-scoped).

Role names are fixed for the initial release; backend permissions must be granular and explicit. Staff cannot switch organizations. They may switch between branches only when their role assignments and branch assignments allow it.

Each role assignment carries its scope explicitly. Branch-scoped assignments include the branch identifier; organization-scoped assignments do not. A staff member may hold different roles at different branches, for example Manager at Branch 1 and Cashier at Branch 2. A role assigned at Branch 1 never grants that role at Branch 2. Branch-scoped authorization requires both the branch-specific role assignment and an active branch assignment for that branch. Revoked assignments, inactive staff, and inactive branches grant no access.

Revoking a branch assignment suspends access; the branch-scoped role row remains active, and re-assigning the same branch restores that role. To remove access permanently, revoke the role assignment as well. Assigning a branch does not itself grant a role; each role must be granted for the branch explicitly. A branch role granted on an inactive branch is inert until the branch is reactivated.

## 5. Customer authorization

Customer operations must be limited to the authenticated customer's own records, with any additional access explicitly defined. A customer must not be able to retrieve another customer's queue entries or profile by changing an identifier. Customer identity never grants staff or organization-management permissions.

## 6. Guest token lifecycle and authorization

### Token issuance
1. The permanent table QR identifies a restaurant, branch, and table; it is not itself a secret authorization token.
2. The backend resolves the table and finds its active dining session.
3. If none exists, the backend atomically creates one active session for that table.
4. The backend generates a separate high-entropy random token for each guest device and associates its hash with the active session.
5. The raw token is returned only to the requesting device over TLS and must not be logged.

### Token use
- Resolve the token only to its associated guest device/session record.
- Permit only explicitly listed public ordering operations.
- Verify the dining session is active on every state-changing request.
- Verify that the session, table, branch, and organization relationships are consistent.
- Never accept a client-selected session ID as proof of access.
- Never use guest tokens to authorize staff operations, payments, menu management, or arbitrary data reads.

### Token invalidation
- Revoke a device token when explicitly revoked or when abuse is detected.
- Invalidate all tokens for a dining session when the session closes.
- Reject tokens associated with closed, expired, or otherwise invalid sessions.
- Define token expiry/rotation duration during detailed design; session closure is a mandatory invalidation boundary.

Store token hashes rather than raw tokens. Use cryptographically secure generation, constant-time comparison where applicable, rate limiting, and abuse controls.

## 7. Authorization enforcement

Authorization must be enforced by trusted backend logic and database policies. Frontend route guards and hidden controls are usability features, not security boundaries.

For each protected operation, validate:
1. Who is calling (registered staff, registered customer, or guest token)?
2. What operation is requested?
3. Which organization, branch, table, and session are involved?
4. Does the caller have the required permission or scoped guest capability?
5. Does the target resource belong to the authorized scope?
6. Is the resource in a state that permits the operation?

## 8. Role and permission lifecycle

The backend must define how staff invitations, membership activation, role changes, branch assignments, suspension, and removal work. Changes must take effect on subsequent authorized operations. Sensitive changes should be auditable.

The owner role must have a safe ownership-transfer and recovery process; avoid accidental removal of the only authorized owner.

## 9. Sessions and account lifecycle

Define and test:
- Supabase Auth session expiry, refresh, logout, and revocation for registered users.
- Disabled or removed staff association.
- Customer account recovery and email verification.
- Invitation expiry and acceptance.
- Behavior after role or branch permission changes.
- Guest token expiry, revocation, and invalidation on dining-session closure.

## 10. Pending decisions

Finalize invitation flow, customer registration/verification requirements, role customization, platform-admin access, guest-token expiry/rotation duration, and the exact profile/mapping schema before implementation. The one-organization-per-staff-account rule and universal customer-account rule are settled decisions, not open questions.
