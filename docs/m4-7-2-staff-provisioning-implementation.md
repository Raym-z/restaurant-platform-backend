# M4.7.2 — Staff Provisioning Implementation

**Status:** local implementation and validation complete. No hosted migration, Edge Function deployment, Auth invitation, account creation, organization, or fixture was created or changed.

**Repositories:**

- Backend: `restaurant-platform-backend-m4-1` — schema, RPCs, Edge Function, contracts, tests, documentation.
- POS: `restaurant-pos-m4-4` — invite form, invitation status panel, acceptance page, tests.

---

## 1. Verdict summary

The M4.7.1 blockers are resolved locally:

- A trusted `staff-invite` Edge Function performs all Supabase Auth Admin work.
- Owner/Admin can create, list, resend, and revoke invitations through narrow RPCs.
- Acceptance is single-use, expiry-bound, email-bound, and replay-safe.
- The one-organization-per-account invariant is preserved.
- A deterministic, idempotent Free plan seed makes `register_organization` usable on a clean deployment.

Final verdict is in §12.

---

## 2. Architecture decisions

### 2.1 Split responsibilities

| Concern                                | Owner                                               | Reason                                       |
| -------------------------------------- | --------------------------------------------------- | -------------------------------------------- |
| Auth identity creation/invitation      | `staff-invite` Edge Function                        | Service-role key stays server-side           |
| Invitation state, authorization, audit | PostgreSQL RPCs                                     | Tenant and role rules belong in the database |
| Invitation token                       | Edge generates; database stores SHA-256 hash        | Raw token never persists or logs             |
| Acceptance                             | Database RPC from the authenticated browser session | Auth email is verified by JWT                |
| Pending invitation UI                  | POS server loader + RPC                             | Read-only status, no client table grants     |

The database is not exposed for direct invitation writes. RLS is enabled and
`anon`/`authenticated` have no table grants; every operation goes through a
reviewed `SECURITY DEFINER` RPC.

### 2.2 Invitation token model

- 32-byte CSPRNG token, base64url encoded (43 characters).
- Stored as a 32-byte SHA-256 digest.
- Single-use: acceptance atomically flips `pending` to `accepted`.
- Expiry: 7 days by default, bounded to 5 minutes–30 days by the database.
- Resend rotates the token, invalidating the previous link.
- The raw token appears only in the Auth email redirect URL. The POS removes it
  from the address bar before showing the acceptance state, hashes it with Web
  Crypto SHA-256, and sends only the lowercase hex digest to the acceptance RPC.
  It never writes the raw token to localStorage, sessionStorage, or cookies.

### 2.2.1 POS acceptance contract correction (M4.7.2-FIX)

The database RPC is authoritative:

```sql
accept_staff_invitation(p_token_hash_hex text)
```

The initial POS integration called the RPC with `p_token` and the raw 43-character
token. The Development deployment preflight identified that mismatch. The POS now:

1. Validates the 43-character base64url token.
2. Computes a SHA-256 digest with Web Crypto.
3. Converts the digest to lowercase hexadecimal.
4. Calls `accept_staff_invitation` with `p_token_hash_hex`.
5. Never passes the raw token to the RPC.

The backend RPC signature, grants, and migrations are unchanged. The full
correction and test evidence are in
`docs/m4-7-2-acceptance-contract-fix.md`.

### 2.3 Email binding and account existence

- Acceptance compares the normalized email on the authenticated `auth.users` row
  (falling back to no other source) to the normalized invited email. Possessing a
  token is insufficient without that session.
- New Auth accounts use `auth.admin.inviteUserByEmail`.
- Existing Auth accounts use a magic link (`signInWithOtp` with
  `shouldCreateUser: false`).
- The Edge Function returns the same success shape in both cases. It does not
  report whether an Auth account existed.
- The API error catalog adds `INVITATION_*` codes and `BRANCH_NOT_ACTIVE`; all
  are mapped in the shared error table and contract tests.

### 2.4 Authorization model

| Actor                      | Invite Admin | Invite Manager/Cashier/Kitchen | List | Resend | Revoke | Accept                |
| -------------------------- | ------------ | ------------------------------ | ---- | ------ | ------ | --------------------- |
| Owner (organization scope) | Yes          | Yes                            | Yes  | Yes    | Yes    | Yes, if email matches |
| Admin (organization scope) | No           | Yes                            | Yes  | Yes    | Yes    | Yes, if email matches |
| Admin (branch scope)       | No           | No                             | No   | No     | No     | Yes, if invited       |
| Manager                    | No           | No                             | No   | No     | No     | Yes, if invited       |
| Cashier                    | No           | No                             | No   | No     | No     | Yes, if invited       |
| Kitchen Staff              | No           | No                             | No   | No     | No     | Yes, if invited       |
| Anonymous                  | No           | No                             | No   | No     | No     | No                    |

Additional rules:

- Manager, Cashier, and Kitchen Staff invitations require branch scope and an
  active branch in the caller's organization.
- An invitation's inviter authority is revalidated at acceptance. A demoted or
  deactivated inviter causes the invitation to fail closed.
- An Admin invitation is revalidated against the inviter still holding the Owner
  role.
- Acceptance creates the staff profile and role assignment in one transaction.
  The existing branch-assignment trigger creates the matching active branch
  assignment.

### 2.5 One organization per account

`staff_profiles.auth_user_id` remains `NOT NULL UNIQUE`. No constraint was
weakened. Acceptance rejects an account that already has any staff profile with
`STAFF_ALREADY_MEMBER`. A second invitation from another organization cannot
create a second membership.

---

## 3. Auth invitation lifecycle

```text
Owner/Admin
  └─ POST /functions/v1/staff-invite { action: "invite", ... }
       ├─ user-scoped RPC: create_staff_invitation(...)
       │    ├─ authorize Owner/Admin
       │    ├─ validate role/scope/branch/email/expiry
       │    ├─ reject duplicate pending invitation
       │    ├─ reject same-org existing staff email
       │    └─ store SHA-256 token hash, status=pending
       ├─ Auth Admin inviteUserByEmail
       │    └─ existing account? magic link instead
       └─ success (same shape for new and existing accounts)

Invitee opens email link
  └─ Supabase verifies Auth session → /accept-invitation?invitation=<raw>
       ├─ browser client loads session from redirect
       ├─ raw token removed from address bar
       └─ RPC accept_staff_invitation(hash)
            ├─ lock invitation row by token hash
            ├─ reject accepted / revoked / expired
            ├─ require JWT email == invitation email
            ├─ require organization active and branch active
            ├─ reject existing staff membership
            ├─ revalidate inviter authority
            ├─ insert staff profile + role assignment
            └─ mark accepted, audit
```

Statuses:

| Status     | Meaning                       | Allowed next actions         |
| ---------- | ----------------------------- | ---------------------------- |
| `pending`  | Delivered, not accepted       | Resend, revoke, accept       |
| `accepted` | Membership created            | None                         |
| `revoked`  | Cancelled by an administrator | None                         |
| `expired`  | Past `expires_at`             | Revoke; create a replacement |

Expiry is evaluated lazily. Acceptance refuses an expired row. Creating a
replacement for the same organization/email marks the stale pending row expired
before inserting, freeing the partial unique index.

Failure behaviour:

- Duplicate pending invitation → `INVITATION_ALREADY_PENDING`.
- Replay → `INVITATION_ALREADY_ACCEPTED`.
- Revoked → `INVITATION_REVOKED`.
- Wrong signed-in email → `INVITATION_EMAIL_MISMATCH`.
- Expired → `INVITATION_EXPIRED`.
- Existing membership → `STAFF_ALREADY_MEMBER`.
- Inactive branch → `BRANCH_NOT_ACTIVE`.
- Delivery failure → `INVITATION_DELIVERY_FAILED`; the created invitation is
  revoked as a compensating action. The Auth user may remain and is harmless.

---

## 4. Organization provisioning behaviour

`register_organization` remains the supported mechanism for a dedicated
organization and its first branch/Owner:

- It requires an authenticated Auth account with no existing staff profile.
- It creates organization, branch, Owner profile, Owner role, and a subscription
  atomically.
- It requires an active Free plan row.
- A dedicated acceptance organization therefore requires a fresh Owner Auth
  account. The existing Development Owner cannot join a second organization.

The new Free plan seed removes the clean-deployment dead end without weakening
branch limits:

- It inserts `free` / `Free` only when no active Free plan exists.
- `branch_limit = 1` is a conservative placeholder, not a commercial decision.
- Existing plan rows are never updated or deleted.
- `create_branch` continues to enforce the plan limit. A dedicated organization
  can create its first branch during registration; adding a second branch
  requires a product-approved plan change.

Recommended acceptance design remains a dedicated organization + branch. The
fallback dedicated branch under the existing organization now requires a plan
with `branch_limit >= 2`, which remains a product decision.

---

## 5. Files changed

### Backend

**New migrations**

- `supabase/migrations/20261110160000_m4_staff_invitations.sql`
- `supabase/migrations/20261110170000_m4_staff_invitation_rpcs.sql`
- `supabase/migrations/20261110180000_free_plan_seed.sql`

**New Edge Function and shared code**

- `supabase/functions/staff-invite/index.ts`
- `supabase/functions/_shared/staffInvite.ts`
- `supabase/functions/_shared/staffInviteDelivery.ts`

**New contracts**

- `src/contracts/staff/invitation.ts`

**Modified backend code**

- `src/contracts/common/errors.ts`
- `src/lib/errors.ts`
- `src/index.ts`
- `supabase/functions/_shared/env.ts`
- `supabase/functions/_shared/http.ts`
- `supabase/functions/_shared/supabase.ts`
- `supabase/functions/_shared/token.ts`
- `tests/integration/security/helpers.ts` (optional extra JWT claims)

**New tests**

- `tests/contract/m4-7-2-staff-invitation-contracts.test.ts`
- `tests/integration/security/m4-7-2-staff-invitations.test.ts`
- `tests/edge/staff-invite-security.test.ts`

**Documentation**

- `docs/m4-7-2-staff-provisioning-implementation.md` (this report)
- `docs/api-and-rpc-contracts.md`
- `docs/authentication-and-authorization.md`
- `docs/backend-services.md`
- `docs/data-model.md`
- `docs/row-level-security.md`
- `README.md`

### POS

**New**

- `src/features/staff/invitation-contracts.ts`
- `src/features/staff/invitation-errors.ts`
- `src/features/staff/invitation-token.ts`
- `src/features/staff/accept-invitation.ts`
- `src/features/staff/actions.ts`
- `src/features/staff/data/invitations.ts`
- `src/features/staff/components/invite-staff-form.tsx`
- `src/features/staff/components/invitations-panel.tsx`
- `src/features/staff/components/accept-invitation-screen.tsx`
- `src/app/(auth)/accept-invitation/page.tsx`
- `src/lib/supabase/client.ts`
- `src/features/staff/__tests__/invitation.test.ts`
- `src/features/staff/__tests__/accept-invitation.test.ts`
- `docs/staff-invitations.md`

**Modified**

- `src/app/(app)/staff/new/page.tsx`
- `src/app/(app)/staff/page.tsx`
- `src/features/staff/components/staff-screen.tsx`
- `src/lib/supabase/session-route.ts`
- `src/lib/supabase/__tests__/session-route.test.ts`
- `src/lib/supabase/database.types.ts`
- `src/i18n/use-labels.ts`
- `src/i18n/messages/en.json`
- `src/i18n/messages/id.json`
- `docs/supabase-integration.md`
- `docs/roles-and-permissions.md`
- `README.md`

Untouched: all existing M4 kitchen migrations, existing uncommitted kitchen test
changes, and `tatus`.

---

## 6. Migration notes

### `20261110160000_m4_staff_invitations.sql`

- Adds `staff_invitation_status` enum and `public.staff_invitations`.
- Composite foreign keys bind branch, inviter, accepter, and revoker to the same
  organization.
- Unique token hash; one pending invitation per organization/email.
- Check constraints enforce normalized email, role/scope rules, token length,
  expiry, send count, and status timestamps.
- RLS enabled; no `anon`/`authenticated` table grants and no policies.

### `20261110170000_m4_staff_invitation_rpcs.sql`

- `create_staff_invitation`, `list_staff_invitations`,
  `revoke_staff_invitation`, `rotate_staff_invitation_token`,
  `accept_staff_invitation`.
- All are `SECURITY DEFINER` with `search_path = ''`.
- Internal helpers live in `private` and are revoked from clients.
- Audit actions: `staff.invitation_created`, `staff.invitation_resent`,
  `staff.invitation_revoked`, `staff.invitation_accepted`.

### `20261110180000_free_plan_seed.sql`

- Conditional idempotent insert only when no active Free plan exists.
- `on conflict (code) do nothing` prevents a primary-key failure on an inactive
  legacy `free` row.
- Does not modify any existing plan.

---

## 7. Test results

All tests below were executed locally.

### Backend static and contract suite

`npm run test:static`:

- Script syntax: 20 scripts checked — pass.
- Migration governance: 45 files, naming/order/immutability/security scan — pass.
- Secret scan: 192 tracked files — pass.
- Blocked-rule register: pass.
- RLS coverage manifest static check: pass.
- Contract drift static check: pass.
- TypeScript typecheck: pass.
- Contract tests: **98 passed** across 9 files, including 12 new M4.7.2
  invitation contract/Edge-helper tests.

### Backend integration suite

Ran against a disposable PostgreSQL 18.2 cluster with Supabase-compatible `auth`
stubs, all 45 migrations applied, no Docker/WSL dependency:

- `tests/integration/security/m4-7-2-staff-invitations.test.ts`: **18 passed**.
- Full integration suite: **155 passed** with `--testTimeout=15000`.
- With the default 5-second timeout, the pre-existing
  `waitlist-and-revocation.test.ts > rate-limits a customer joining many branches`
  test timed out once; it passes alone and passes in the full suite with the
  higher timeout. No M4.7.2 file touches that test.

Covered authorization and lifecycle cases:

- Owner invites Manager; token hash stored, raw token absent from response.
- Duplicate pending invitation rejected.
- Admin invites branch roles; Admin cannot invite Admin.
- Manager, Cashier, and Kitchen Staff denied.
- Invalid role and invalid organization scope rejected.
- Cross-organization branch rejected.
- Existing same-organization staff email rejected.
- Wrong-email acceptance rejected.
- Successful acceptance creates profile, role, and branch assignment atomically.
- Replay returns `INVITATION_ALREADY_ACCEPTED`.
- Second organization membership blocked.
- Expired acceptance rejected; replacement marks the stale row expired.
- Token rotation invalidates the old link.
- Revoke is audited.
- Cross-organization list/revoke/resend isolation.
- Branch deactivated after invitation → `BRANCH_NOT_ACTIVE`, no membership.
- Free plan seed enables `register_organization`; second branch blocked by limit.
- Invitation list never exposes token material.
- Demoted inviter → `INVITATION_REVOKED`, no partial membership.

### Edge Function

- `deno check` on `staff-invite/index.ts`: pass.
- `deno test --allow-all tests/edge`: **10 passed** (2 existing guest tests, 8 new
  invitation token/redirect/error-classification/delivery-path tests).

Not run: live Edge Function HTTP tests against local Supabase Auth, because the
Supabase Docker stack is unavailable in this environment. The Edge runtime path
is validated by type-checking and pure helper tests, not by a live Auth call.

### POS

- `npm run typecheck`: pass.
- `npm run lint`: pass.
- `npm test`: **201 passed** (including 9 focused acceptance-contract tests, 11
  invitation contract/error/i18n tests, and 2 acceptance-route tests).
- `npm run build`: pass; `/accept-invitation`, `/staff`, and `/staff/new` build.
- `npx prettier --check` on new acceptance files: pass after formatting.

---

## 8. Security review

| Requirement                                 | Implementation                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------------------ |
| Service-role operations server-side only    | `staff-invite` Edge Function only; POS never receives the key                  |
| Never trust client organization/branch/role | RPCs derive actor/org from JWT and staff profile; branch ownership rechecked   |
| Invitation bound to organization and branch | Composite FKs and RPC validation                                               |
| Token possession alone insufficient         | Authenticated JWT email must match invitation                                  |
| Cashier/Kitchen cannot invite               | RPC requires organization-scoped Owner/Admin                                   |
| Kitchen Staff no station-management gain    | No change to kitchen authorization; invitation only creates the granted role   |
| Preserve Owner/Admin/Manager boundaries     | Admin cannot invite Admin; Owner-only Admin invitations                        |
| Expiry, single-use, replay protection       | `expires_at`, `pending`→`accepted`, `FOR UPDATE`, replay error                 |
| Avoid Auth account enumeration              | Same Edge response for new/existing accounts; no account lookup exposed to POS |
| No token/PII logging                        | No request-body or token logging; audit excludes token material                |
| Raw token never sent to the RPC             | POS hashes with SHA-256 and sends only `p_token_hash_hex`                      |
| No direct member/invitation writes          | RLS + no grants; RPC-only                                                      |

Residual risk: timing differences between `inviteUserByEmail` and magic-link
delivery could theoretically hint at account existence to a determined
authenticated administrator. The response body and status are identical.

Residual risk: an authorized Owner/Admin can call the RPC directly with their own
token hash and skip the Edge Function's email delivery. They are already
authorized to invite; acceptance still requires a matching authenticated email
and a valid unexpired token. No privilege escalation results.

---

## 9. Remaining blockers and limits

| ID     | Item                                                            | Impact                                                                                                                                            | Resolution                                                                                                                                  |
| ------ | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| M472-0 | Dedicated organization still needs one fresh Owner Auth account | `register_organization` requires an authenticated account with no staff profile; the existing Development Owner cannot join a second organization | Approved operator creates/invites the Owner Auth account, then the Owner calls `register_organization` through the approved onboarding path |
| M472-1 | Hosted migration/Edge deployment not approved                   | No hosted invitations yet                                                                                                                         | Separate approval required                                                                                                                  |
| M472-2 | Auth SMTP and redirect URLs not configured on Development       | Edge delivery fails                                                                                                                               | Configure Email provider, SMTP, and `${POS_URL}/accept-invitation` allow-list                                                               |
| M472-3 | Free plan `branch_limit = 1` is a placeholder                   | A second branch under an existing org is blocked                                                                                                  | Product decision; dedicated acceptance org needs one branch only                                                                            |
| M472-4 | Legacy staff directory/edit/deactivate remain mock              | Staff list below the invitation panel is not live                                                                                                 | Out of M4.7.2 scope; invitations and acceptance are live                                                                                    |
| M472-5 | No live local Supabase Auth stack                               | Edge HTTP/Auth delivery not executed                                                                                                              | Run `npm run test:edge` with Supabase/Docker before hosted deploy                                                                           |
| M472-6 | pgTAP suite not run                                             | No pgTAP evidence                                                                                                                                 | Local stack/Docker unavailable; integration suite covers the behavior                                                                       |
| M472-7 | `BLK-008` Realtime delivery still unverified                    | KDS Realtime remains polling-fallback                                                                                                             | Unrelated M4.3 blocker                                                                                                                      |

---

## 10. Hosted configuration and deployment requirements

Do not perform these until separately approved. No secret values are recorded
here.

### Owner bootstrap for a dedicated organization

`register_organization` still requires an already-authenticated Auth account with
no staff profile. For a dedicated acceptance organization:

1. An approved operator creates or invites exactly one Owner Auth account through
   Supabase Auth Admin. This is the only remaining out-of-band identity step.
2. The Owner signs in and calls `register_organization` through the approved
   onboarding path. The RPC creates the organization, first branch, Owner profile,
   Owner role, and Free subscription atomically.
3. That Owner then uses the POS invite flow for the four acceptance roles.

Do not grant Owner through an invitation; the existing model deliberately forbids
it. If the existing Development Owner is reused instead, the acceptance tenancy
must be a branch under the existing organization and the subscription must allow
at least two active branches.

### Migrations

Apply the three new migrations in timestamp order using the approved deployment
process:

1. `20261110160000_m4_staff_invitations.sql`
2. `20261110170000_m4_staff_invitation_rpcs.sql`
3. `20261110180000_free_plan_seed.sql`

Verify after deployment:

- `staff_invitations` exists with RLS enabled and no client table grants.
- The five invitation RPCs exist and are executable by `authenticated`.
- Exactly one active Free plan exists; its `branch_limit` is confirmed.

### Edge Function

Deploy `staff-invite` with the platform's default JWT verification. Required
server configuration:

| Name                                              | Purpose                                                                  |
| ------------------------------------------------- | ------------------------------------------------------------------------ |
| `SUPABASE_URL`                                    | Provided by the platform                                                 |
| `SUPABASE_SERVICE_ROLE_KEY`                       | Provided by the platform; never sent to POS                              |
| `SUPABASE_ANON_KEY` or `SUPABASE_PUBLISHABLE_KEY` | User-scoped RPC and OTP client                                           |
| `POS_ACCEPT_INVITATION_URL`                       | Absolute POS acceptance URL, e.g. `https://<pos-host>/accept-invitation` |
| `CORS_ALLOWED_ORIGINS`                            | Comma-separated allowed POS origins                                      |
| `STAFF_INVITATION_TTL_SECONDS`                    | Optional; default 604800, allowed 300–2592000                            |

### Supabase Auth

- Enable the Email provider.
- Configure SMTP so invite and magic-link emails are delivered.
- Add the POS acceptance URL to the Auth redirect allow-list.
- Confirm the Invite and Magic Link email templates preserve `redirect_to`.
- Confirm the project Site URL points at the POS host, not Production.

### POS

- `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` continue
  to target Development only.
- `NEXT_PUBLIC_APP_URL` must match the deployed POS origin used in redirects.
- Redeploy the POS after the backend function is available.

---

## 11. What this milestone did not do

- No hosted migration, SQL write, or schema change.
- No Edge Function deployment.
- No Auth user, invitation, account, organization, branch, role, or fixture
  created on hosted Development.
- No Production contact.
- No commit, push, merge, branch switch, worktree, or deployment.
- No modification of existing M4 kitchen migrations or unrelated uncommitted
  work.
- No secret, token, password, or environment value printed or stored.

Preserved worktree state:

- POS `agent/pos-m4-4-kds-frontend` @ `ed29be5`; pre-existing docs/tests changes
  and `tatus` untouched.
- Backend `feature/m4-1-kitchen-infrastructure` @ `864591b`; pre-existing
  `m4-kitchen-kds-read.test.ts` and `m4-kitchen-ticket-lifecycle.test.ts`
  modifications untouched.

---

## 12. Verdict

**READY FOR LOCAL PROVISIONING VALIDATION.**

The previously missing mechanism now exists: trusted Auth invitation, database
invitation state, single-use email-bound acceptance, role/scope enforcement, and
an idempotent Free plan seed. Local schema, RPC, Edge-type, contract, integration,
POS unit, lint, typecheck, and production-build checks pass.

The M4.7.2-FIX correction aligns the POS client with the authoritative
`accept_staff_invitation(p_token_hash_hex)` signature. The POS hashes the raw
invitation token with SHA-256 and sends only the hexadecimal digest. No backend
migration or RPC signature was changed.

Hosted provisioning remains blocked only by the separate deployment approvals and
Auth/SMTP/redirect configuration listed in §10. No hosted change was made while
preparing this implementation.
