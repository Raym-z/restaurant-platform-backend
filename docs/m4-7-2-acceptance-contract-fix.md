# M4.7.2-FIX — Invitation Acceptance Contract Alignment

**Status:** local fix and validation complete. No hosted database access, migration,
Edge Function deployment, Auth change, invitation, account, fixture, commit, push,
merge, or deployment was performed.

**Scope:** POS acceptance flow only. The backend RPC remains authoritative.

---

## 1. Original mismatch

The Development deployment preflight found that the POS acceptance client and the
database RPC disagreed on both the argument name and the value.

POS call site before the fix:

```text
src/features/staff/components/accept-invitation-screen.tsx
  supabase.rpc("accept_staff_invitation", { p_token: token })
```

Generated POS type before the fix:

```text
src/lib/supabase/database.types.ts
  accept_staff_invitation: { Args: { p_token: string } }
```

Authoritative database RPC:

```text
supabase/migrations/20261110170000_m4_staff_invitation_rpcs.sql
  create or replace function public.accept_staff_invitation(p_token_hash_hex text)
```

The RPC requires a 64-character lowercase SHA-256 hex digest:

```text
if p_token_hash_hex is null or p_token_hash_hex !~ '^[0-9a-f]{64}$' then
  ... INVITATION_NOT_FOUND ...
end if;

where i.token_hash = decode(p_token_hash_hex, 'hex')
```

Impact: the POS supplied the raw 43-character token under the wrong argument
name. PostgREST could not resolve `p_token`, and a correctly named raw token would
still fail the 64-hex validation. Invitation acceptance could not succeed through
the POS.

---

## 2. Corrected implementation

The POS now performs the same digest operation that the Edge Function performs
when creating the invitation:

1. Accept only a 43-character base64url token from the invitation URL.
2. Hash the raw token with Web Crypto `SHA-256`.
3. Convert the digest to lowercase hexadecimal.
4. Call `accept_staff_invitation` with `p_token_hash_hex`.
5. Never send the raw token to the RPC.

Corrected call:

```ts
const result = await acceptStaffInvitation(
  (functionName, args) => supabase.rpc(functionName, args),
  token,
);
```

The helper computes and sends:

```ts
await callRpc("accept_staff_invitation", {
  p_token_hash_hex: tokenHash,
});
```

`tokenHash` is the lowercase 64-character SHA-256 hex digest of the raw token.
The raw token remains only in component state and is removed from the address bar
before the RPC call.

---

## 3. Files changed

### POS: source

- `src/features/staff/invitation-token.ts` — token validation and Web Crypto
  SHA-256 hex helper.
- `src/features/staff/accept-invitation.ts` — hash-and-call helper, RPC result
  validation, and error normalization.
- `src/features/staff/components/accept-invitation-screen.tsx` — uses the helper;
  no direct RPC call or raw-token argument.
- `src/app/(auth)/accept-invitation/page.tsx` — uses the shared token validator.
- `src/lib/supabase/database.types.ts` — RPC argument is now
  `p_token_hash_hex: string`.

### POS: tests and documentation

- `src/features/staff/__tests__/accept-invitation.test.ts` — new focused suite.
- `docs/staff-invitations.md` — records the SHA-256 digest handoff.

### Backend: documentation only

- `docs/m4-7-2-staff-provisioning-implementation.md` — records the correction and
  updated POS test evidence.
- `docs/m4-7-2-acceptance-contract-fix.md` — this report.

**No backend source, migration, RPC, Edge Function, or backend generated
contract was modified.** The migration and RPC signature remain exactly as
reviewed. The POS-local `database.types.ts` was updated to match the backend
argument name.

---

## 4. Tests added

`src/features/staff/__tests__/accept-invitation.test.ts` covers:

- Standard SHA-256 lowercase hex output (`sha256Hex("abc")` known vector).
- Web Crypto output matches Node SHA-256 for a realistic 43-character token.
- The digest is exactly 64 lowercase hexadecimal characters.
- Token validation accepts exactly 43 base64url characters.
- The RPC is called as `accept_staff_invitation` with exactly
  `{ p_token_hash_hex: <digest> }`.
- There is no `p_token` argument and no raw token value in the RPC arguments.
- The success response is validated with the existing
  `AcceptStaffInvitationResponseSchema`.
- Missing, empty, short, and overlong tokens never reach the RPC.
- RPC application errors are normalized with their safe message.
- Thrown transport failures are normalized as retryable.
- Incomplete success responses are reported as invalid.
- The acceptance screen delegates to the hash-based helper and contains no
  `p_token:` argument. This is the regression test that would have failed with the
  previous implementation.

---

## 5. Validation results

Run in `restaurant-pos-m4-4`:

| Command                                                                                         | Result                                                       |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `npm run typecheck`                                                                             | Pass                                                         |
| `npm run lint`                                                                                  | Pass                                                         |
| Focused invitation tests (`tsx --test` on `accept-invitation.test.ts` and `invitation.test.ts`) | **20 passed** (9 new + 11 existing)                          |
| `npm test`                                                                                      | **201 passed**, 0 failed                                     |
| `npm run build`                                                                                 | Pass; `/accept-invitation`, `/staff`, and `/staff/new` build |

No backend test suite was rerun because no backend source or migration changed.

---

## 6. Backend and migration status

Confirmed unchanged:

- `20261110160000_m4_staff_invitations.sql`
- `20261110170000_m4_staff_invitation_rpcs.sql`
- `20261110180000_free_plan_seed.sql`
- `accept_staff_invitation(p_token_hash_hex text)`
- All RPC grants, RLS, and Edge Function code

The deployment preflight's acceptance-contract blocker is resolved. The unrelated
preflight blockers remain: hosted POS origin, Auth SMTP/redirect configuration,
Edge secrets, and explicit deployment approval.

---

## 7. Result

The POS acceptance flow is aligned with the deployed RPC contract. The raw token is
never sent to the database. Local typecheck, lint, focused tests, full POS tests,
and production build pass.

**READY FOR LOCAL VALIDATION REVIEW.**
