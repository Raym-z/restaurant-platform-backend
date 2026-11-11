# M4.7.2 — Development Deployment Preflight

**Status:** preflight complete. No hosted migration, Edge Function deployment, secret change, Auth setting change, invitation email, account, organization, branch, or fixture was created or modified.

**Date:** 2026-11-10

**Repositories:**

- Backend: `restaurant-platform-backend-m4-1`
- POS: `restaurant-pos-m4-4`

---

## 1. Target project verification

| Check                                 | Result                                                     |
| ------------------------------------- | ---------------------------------------------------------- |
| Linked project ref                    | `bnticbeepxwhrzimouuh`                                     |
| Linked project name                   | `Development Branch - Restaurant`                          |
| Production ref `xzchsyxhpknlogwcfsll` | Not contacted                                              |
| Commands used                         | All remote commands passed `--remote=bnticbeepxwhrzimouuh` |

`supabase/.temp/linked-project.json` resolves to `bnticbeepxwhrzimouuh`. The
Supabase CLI prints `· production` beside the target because this is the main
branch of the Supabase project, not a preview branch. That label is not the
Production project. The ref is exactly the Development ref supplied for this
task.

No command in this preflight targeted the Production ref.

---

## 2. Repository state and file integrity

### Branches and existing work

| Repository | Branch                                | HEAD      |
| ---------- | ------------------------------------- | --------- |
| Backend    | `feature/m4-1-kitchen-infrastructure` | `864591b` |
| POS        | `agent/pos-m4-4-kds-frontend`         | `ed29be5` |

Existing uncommitted changes were preserved. The POS `tatus` file remains
tracked, 916 bytes, with zero diff. No commit, push, merge, branch switch,
worktree, or deployment was performed.

### Migration files

The three M4.7.2 migration files exist:

| Migration                                     | Lines | SHA-256 (current worktree)                                         |
| --------------------------------------------- | ----: | ------------------------------------------------------------------ |
| `20261110160000_m4_staff_invitations.sql`     |   137 | `FD80C911B97D3EF0725A303A6087E5D368DF32A611D7281111497502BFB67995` |
| `20261110170000_m4_staff_invitation_rpcs.sql` |   800 | `E6C11778990850B1D9937CE679C837E4082763F1AD6A0560869B5EA80DB17473` |
| `20261110180000_free_plan_seed.sql`           |    25 | `4FD98D3EFF31693D36D33A80442CA7201E2BD819D35B3B3CD00807980B3BC16`  |

`git status -- supabase/migrations` shows only these three untracked files. No
existing tracked migration is modified, deleted, or renamed. No other migration
file changed during this preflight.

The reviewed content is consistent with the M4.7.2 implementation report:

- `staff_invitations` is additive, RLS-enabled, with no `anon`/`authenticated`
  table grants.
- Invitation RPCs are `SECURITY DEFINER`, use an empty `search_path`, and expose
  no token material.
- The Free plan seed is conditional and idempotent.

### Edge Function

- Function name: `staff-invite`
- Deployment path: `supabase/functions/staff-invite/index.ts`
- Shared helpers: `supabase/functions/_shared/staffInvite.ts`,
  `supabase/functions/_shared/staffInviteDelivery.ts`
- `deno check --config supabase/functions/deno.json
supabase/functions/staff-invite/index.ts` completed with exit code 0.
- No `[functions.staff-invite]` override exists in `supabase/config.toml`, so
  JWT verification will use the platform default (enabled) when deployed
  without `--no-verify-jwt`.

`npx supabase functions list --remote=bnticbeepxwhrzimouuh` currently returns no
deployed functions. This would be the first Edge Function deployment for the
project.

### Secret exposure check

- `npm run verify:secrets` scanned 195 tracked files and found no credential
  patterns.
- POS source contains only defensive checks against `sb_secret_`/`sbp_` and
  `service_role` keys. No privileged key is bundled into frontend code.
- No secret values were printed during this preflight.

---

## 3. Hosted migration preflight

### Migration list

Command:

```powershell
npx supabase migration list --remote bnticbeepxwhrzimouuh
```

Result:

- 45 local migration files.
- 42 migrations present remotely.
- 3 pending migrations.
- Last remote migration: `20261110150000`.
- No local/remote mismatch, gap, or ordering discrepancy before the pending
  entries.

Pending migrations:

```text
20261110160000_m4_staff_invitations.sql
20261110170000_m4_staff_invitation_rpcs.sql
20261110180000_free_plan_seed.sql
```

### Dry run

Command:

```powershell
npx supabase db push --dry-run --remote=bnticbeepxwhrzimouuh
```

Result:

```text
DRY RUN: migrations will *not* be pushed to the database.
Would push these migrations:
 • 20261110160000_m4_staff_invitations.sql
 • 20261110170000_m4_staff_invitation_rpcs.sql
 • 20261110180000_free_plan_seed.sql
```

The dry run proposed exactly the three expected migrations. No seeds or custom
roles were proposed. No migration history repair was attempted.

### Post-deployment verification (not performed)

After a separately approved `db push`, verify:

- `public.staff_invitations` exists with RLS enabled.
- `anon` and `authenticated` have no table privileges on
  `public.staff_invitations`.
- The five invitation RPCs exist and are executable by `authenticated`.
- Exactly one active Free plan exists; confirm its `branch_limit`.
- `npx supabase migration list --remote=bnticbeepxwhrzimouuh` reports all three
  migrations as applied.

The migration deployment itself is ready. It is not the only blocker for a
functional M4.7.2 release; see §6.

---

## 4. Edge Function deployment readiness

### Configuration contract

The function reads these names. No values are recorded here.

| Name                                              | Source            | Required         | Purpose                                                                  |
| ------------------------------------------------- | ----------------- | ---------------- | ------------------------------------------------------------------------ |
| `SUPABASE_URL`                                    | Platform-provided | Yes              | Supabase project URL                                                     |
| `SUPABASE_SERVICE_ROLE_KEY`                       | Platform-provided | Yes              | Auth Admin and service client; never sent to POS                         |
| `SUPABASE_ANON_KEY` or `SUPABASE_PUBLISHABLE_KEY` | Platform-provided | Yes, one of them | User-scoped RPC and magic-link client                                    |
| `POS_ACCEPT_INVITATION_URL`                       | Custom secret     | Yes              | Absolute POS acceptance URL, e.g. `https://<pos-host>/accept-invitation` |
| `CORS_ALLOWED_ORIGINS`                            | Custom secret     | Optional         | Comma-separated POS origins; defaults to `*` when unset                  |
| `STAFF_INVITATION_TTL_SECONDS`                    | Custom secret     | Optional         | Default `604800`; allowed `300`–`2592000`                                |

Current custom Edge secrets:

```text
npx supabase secrets list --remote=bnticbeepxwhrzimouuh
→ {"secrets":[]}
```

No custom secret is currently configured. In particular,
`POS_ACCEPT_INVITATION_URL` is missing. The function reads it during every
request and returns `SERVICE_UNAVAILABLE` if it is absent. Platform-provided
secrets are not shown by `secrets list`; confirm they are present in the hosted
runtime after deployment.

`CORS_ALLOWED_ORIGINS` should be set to the deployed POS origin. Leaving it
unset defaults to `*`, which is functional but broader than necessary. The POS
invite action is server-side, so browser CORS is primarily relevant to direct
Edge calls and operational diagnostics.

### JWT verification

Deploy without `--no-verify-jwt`. There is no local config override, so JWT
verification remains enabled by default. The function also validates the bearer
token and checks the caller through `auth.getUser`. It does not rely on the
gateway alone.

### Deployment bundling risk

The function imports shared code from outside `supabase/functions`
(`../../../src/contracts/...`, `../../../src/lib/errors.ts`). The same pattern is
used by the existing guest functions. `deno check` resolves the graph locally,
but this environment has no Docker/local Supabase stack, and the CLI has no
deployment dry-run. Bundling with `--use-api` has not been exercised. Verify the
deployed function's startup logs immediately after deployment, before enabling
invitations.

### Deployment command (after approval)

```powershell
npx supabase functions deploy staff-invite --remote=bnticbeepxwhrzimouuh --use-api --yes
```

`--use-api` avoids the unavailable local Docker bundler. Do not add
`--no-verify-jwt`. If a Docker-capable environment is available, standard
bundling can be used instead, but it is not available here.

---

## 5. Supabase Auth configuration

### Repository evidence

`supabase/config.toml` is a **local stack** configuration. It is not evidence of
the hosted Development Auth settings.

Current local values:

| Setting                     | Local value                    |
| --------------------------- | ------------------------------ |
| Auth enabled                | `true`                         |
| Email provider              | `true`                         |
| Email confirmations         | `false`                        |
| Site URL                    | `http://127.0.0.1:3000`        |
| Additional redirect URLs    | `https://127.0.0.1:3000`       |
| SMTP block                  | Commented out / not configured |
| Invite/Magic Link templates | Local defaults                 |

This preflight did not read hosted Auth settings; the CLI surface used here does
not expose them. They require manual Dashboard verification. No Auth setting was
changed.

### Required hosted configuration

- Enable the Email provider.
- Configure a production-capable SMTP provider for invitation and magic-link
  delivery. The built-in email service is rate-limited; confirm it can deliver
  to the intended acceptance recipients.
- Set the Auth Site URL to the POS origin.
- Add the exact acceptance URL to the redirect allow-list:
  `${POS_URL}/accept-invitation`.
- Confirm the Invite and Magic Link email templates preserve `redirect_to`.
- Confirm email rate limits are adequate for the acceptance run.
- Confirm the project is Development (`bnticbeepxwhrzimouuh`), not Production.

### Missing information needed before deployment

1. The hosted POS origin, or an explicit decision to use a local/tunnel URL for
   smoke testing. The current POS `NEXT_PUBLIC_APP_URL` is localhost, and no POS
   hosting configuration exists in the repository.
2. Confirmation that hosted Auth SMTP is configured and can deliver to the
   controlled acceptance addresses.
3. Confirmation of the hosted Auth Site URL and redirect allow-list.
4. The controlled acceptance email domain/addresses and approval for one smoke
   invitation.
5. Explicit approval to apply the migrations and deploy the function.

---

## 6. Blocking defect: acceptance RPC contract mismatch

This is a functional blocker discovered during preflight. Per the task
restrictions, no application source or migration was modified.

### Evidence

POS call site:

```text
src/features/staff/components/accept-invitation-screen.tsx:79
  const { data, error } = await supabase.rpc("accept_staff_invitation", {
    p_token: token,
  });
```

POS generated type:

```text
src/lib/supabase/database.types.ts:850
  accept_staff_invitation: {
    Args: { p_token: string };
```

Database RPC:

```text
supabase/migrations/20261110170000_m4_staff_invitation_rpcs.sql:509
  create or replace function public.accept_staff_invitation(p_token_hash_hex text)
```

The same function requires a 64-character lowercase hex digest:

```text
:542  if p_token_hash_hex is null or p_token_hash_hex !~ '^[0-9a-f]{64}$'
:552  where i.token_hash = decode(p_token_hash_hex, 'hex')
```

### Impact

The POS sends a 43-character raw base64url invitation token under the wrong
argument name. PostgREST cannot resolve `p_token` against the function signature
`p_token_hash_hex`. Even if the argument name matched, the raw token would fail
the 64-hex validation and return `INVITATION_NOT_FOUND`.

Acceptance therefore cannot succeed through the POS today. This was not caught by
the local suite because the integration tests call
`accept_staff_invitation($1)` directly with a SHA-256 hash, not through the POS
client.

The backend contract `AcceptStaffInvitationRequestSchema` also defines a `token`
field, but no Edge acceptance function uses it. This is contract drift.

### Required fix before deployment

Choose one, implement it, and add a POS-to-RPC contract test:

- **Option A (recommended):** compute the SHA-256 hex digest of the raw token in
  the POS browser client and call `p_token_hash_hex`; update
  `database.types.ts` to match.
- **Option B:** add a server-side acceptance endpoint that hashes the raw token
  and calls the RPC; update the POS to call that endpoint.
- **Option C:** change the RPC to accept the raw token and hash internally.
  This broadens raw-token handling in SQL and requires coordinated contract and
  test changes.

No fix was applied during this preflight.

---

## 7. Deployment sequence after approval

Database migration deployment and Edge Function deployment remain separate
operations.

### Step 1 — Resolve blockers

Before any hosted change:

- Fix the acceptance RPC mismatch in §6.
- Decide the POS acceptance origin.
- Verify hosted Auth SMTP, Site URL, and redirect allow-list.
- Obtain explicit approval for the hosted changes.

### Step 2 — Apply migrations

```powershell
npx supabase db push --dry-run --remote=bnticbeepxwhrzimouuh
npx supabase db push --remote=bnticbeepxwhrzimouuh --yes
```

Then verify the migration list and the post-deployment checklist in §3.

### Step 3 — Configure Edge secrets

Set only the non-platform values after the POS origin is known:

```powershell
npx supabase secrets set POS_ACCEPT_INVITATION_URL="https://<pos-host>/accept-invitation" CORS_ALLOWED_ORIGINS="https://<pos-host>" --remote=bnticbeepxwhrzimouuh --yes
```

Optional:

```powershell
npx supabase secrets set STAFF_INVITATION_TTL_SECONDS=<300-2592000> --remote=bnticbeepxwhrzimouuh --yes
```

Do not put secret values in the repository, this report, or a committed `.env`
file.

### Step 4 — Deploy the Edge Function

```powershell
npx supabase functions deploy staff-invite --remote=bnticbeepxwhrzimouuh --use-api --yes
npx supabase functions list --remote=bnticbeepxwhrzimouuh
npx supabase secrets list --remote=bnticbeepxwhrzimouuh
```

Confirm the function is deployed, JWT verification is enabled, and the required
secret names are present. Check startup logs for missing configuration or
bundling errors.

### Step 5 — Verify Auth configuration

Perform the Dashboard checks in §5. Do not send an invitation until SMTP and the
redirect allow-list are confirmed.

### Step 6 — Minimal smoke test (separate approval)

After separate approval, invite one controlled account through the POS, complete
the email link, and accept it. This validates:

- Auth invitation/magic-link delivery.
- Redirect to `${POS_URL}/accept-invitation`.
- Session establishment.
- Successful single-use acceptance and staff membership creation.

Do not run the five-role acceptance matrix until this smoke test passes.

---

## 8. Remaining blockers

| ID      | Blocker                                                                                       | Impact                                                                                         | Resolution                                                                                      |
| ------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| M472-P1 | POS acceptance sends `p_token` raw; RPC expects `p_token_hash_hex`                            | Acceptance fails for every invited staff member                                                | Fix per §6 and add a POS-to-RPC contract test                                                   |
| M472-P2 | No hosted POS origin; POS `NEXT_PUBLIC_APP_URL` is localhost and no deployment config exists  | `POS_ACCEPT_INVITATION_URL` cannot be finalized; email links are not usable by remote invitees | Deploy POS to a stable HTTPS origin, or explicitly approve a local/tunnel smoke plan            |
| M472-P3 | No custom Edge secrets configured; `POS_ACCEPT_INVITATION_URL` absent                         | `staff-invite` returns `SERVICE_UNAVAILABLE` on every request                                  | Set the required secret after the POS origin is known                                           |
| M472-P4 | Hosted Auth SMTP and redirect allow-list not verified                                         | Invitation emails may not deliver, or the redirect may be rejected                             | Configure and verify in the Supabase Dashboard                                                  |
| M472-P5 | Edge bundling outside `supabase/functions` not exercised with `--use-api`; Docker unavailable | First deployment could fail at bundle/startup                                                  | Deploy and inspect startup logs before enabling invitations                                     |
| M472-P6 | Free plan seed is conditional; current hosted plan state was not queried                      | A pre-existing inactive `free` row could leave no active Free plan                             | Verify exactly one active Free plan after migration; coordinate a product decision if absent    |
| M472-P7 | Explicit hosted deployment approval not yet granted                                           | No hosted change is authorized                                                                 | Obtain approval for migrations, secrets, function deployment, and Auth configuration separately |

---

## 9. Verdict

The migration set itself is ready: 42 previously deployed migrations, exactly
three pending M4.7.2 migrations, and a dry run that proposes only those three.

The deployment is **not** ready for approval as a functional M4.7.2 release. The
POS acceptance call is incompatible with the deployed RPC signature, and the
hosted POS/Auth/secret prerequisites are not in place. No hosted change was made
during this preflight.

**BLOCKED — DEPLOYMENT PREREQUISITES MISSING**
