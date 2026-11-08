# Test Traceability

Maps approved requirements to test families. Detailed cases are added as Agent 1
and Agent 2 implementations land.

| Test family | Source | Status |
|---|---|---|
| `T-ENV-*` | `implementation-roadmap.md` Phase 1; `local-testing.md` | Ready (harness) |
| `T-CLI-*` | `database-architecture.md` §11 | Ready (harness) |
| `T-MIG-*` | `database-architecture.md` §11, §13 | Ready (static gate) |
| `T-SCH-*` | `database-architecture.md` §4–§5; `data-model.md` §10 | Blocked on Agent 1 schema |
| `T-RLS-*` | `row-level-security.md` §3, §10 | Blocked on Agent 2 policies |
| `T-AUTH-*` | `authentication-and-authorization.md` §4, §7; `api-and-rpc-contracts.md` §20.1 | Partially ready (five-role helpers); blocked on policies/RPCs |
| `T-RPC-*` | `api-and-rpc-contracts.md` §8–§9, §20.2 | Blocked on Agent 2 RPCs |
| `T-GST-*` | `security-guidelines.md` §5; `api-and-rpc-contracts.md` §8.7, §20.4 | Blocked on Agent 2 Edge/RPCs; expiry duration blocked (`BLK-003`) |
| `T-TXN-*` | `data-model.md` §11; `api-and-rpc-contracts.md` §20.2 | Partially blocked (`BLK-001`, `BLK-002`) |
| `T-WLT-*` | `data-model.md` §7, §11.8 | Blocked on Agent 2; restriction behavior blocked (`BLK-004`) |
| `T-SUB-*` | `api-and-rpc-contracts.md` §17, §20.3 | Blocked on Agent 1 state model + Agent 2 enforcement |
| `T-HIS-*` | `database-architecture.md` §9; `api-and-rpc-contracts.md` §18, §20.5 | Blocked on schema/RPCs |
| `T-EDGE-*` | `api-and-rpc-contracts.md` §10, §20 | Blocked on Agent 2 functions |
| `T-CONTRACT-*` | `api-and-rpc-contracts.md` §4–§6, §20 | Blocked on Agent 2 contracts |
| `T-RT-*` | `realtime-architecture.md` §9 | Deferred/blocked (`BLK-008`) |
| `T-SEC-*` | `security-guidelines.md` §13 | Ready (static), database portions blocked |
| `T-CI-*` | `implementation-roadmap.md` Phase 1, Phase 11 | Ready |

## M2.1 per-branch role coverage

| Scenario | Test |
|---|---|
| Manager at Branch A and Cashier at Branch B resolve per branch | `supabase/tests/database/010_staff_branch_roles.test.sql`; `tests/integration/security/branch-scoped-staff-roles.test.ts` |
| Manager at A cannot obtain Manager at B | both files above |
| Cashier at B cannot obtain Cashier at A | both files above |
| Organization Owner/Admin remain organization-wide | both files above |
| Revoked role or branch assignment grants no access | both files above |
| Inactive staff or inactive branch denied | both files above |
| Cross-organization and foreign-branch assignment rejected | both files above |
| Duplicate active assignment and revoked replacement | both files above |
| One-active-Owner invariant retained | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Legacy backfill split and fail-closed behavior | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Revoked legacy row with no assignment history fails closed | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Branch-scoped Admin denied organization-level operations | `tests/integration/security/branch-scoped-staff-roles.test.ts` |
| Branch assignment without a role grants no access | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Direct branch role insert and branch move maintain assignments | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Branch-aware `has_permission` behavior | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Grant/revoke audit events include branch context | `tests/integration/security/branch-scoped-staff-roles.test.ts` |
| Concurrent different-role grants at one branch both succeed | `tests/integration/security/branch-scoped-staff-roles.test.ts` |
| Concurrent revocations serialize and write one audit event | `tests/integration/security/branch-scoped-staff-roles.test.ts` |
| Concurrent branch-assignment revocations serialize and audit once | `tests/integration/security/staff-rpc-concurrency.test.ts` |
| Organization lock precedes role-assignment row lock | `tests/integration/security/staff-rpc-concurrency.test.ts` |
| Grant and revoke serialize without deadlock or lost audit | `tests/integration/security/staff-rpc-concurrency.test.ts` |
| Backfill holds a SHARE lock on `staff_branch_assignments` | `tests/integration/security/staff-rpc-concurrency.test.ts`; `010_staff_branch_roles.test.sql` |
| Active legacy role with only revoked assignments fails, then restores after reassignment | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Organization-scoped `has_permission` validates supplied branch tenant/status | `supabase/tests/database/010_staff_branch_roles.test.sql` |
| Missing and cross-tenant staff errors share code/detail | `tests/integration/security/cross-tenant-errors.test.ts` |
| M2 branch helper carrying `branch_id` is the M3 integration fixture | `tests/integration/security/helpers.ts` |
| Contract requires branch for branch-scoped grants | `src/contracts/common/contracts.test.ts` |
| Revoke role response contract is typed | `src/contracts/common/contracts.test.ts` |

## Special-attention coverage

| Requirement | Primary suites |
|---|---|
| Cross-organization access | `T-RLS-*`, `T-AUTH-*` |
| Cross-branch authorization | `T-RLS-*`, `T-AUTH-*` |
| Concurrent QR scans/session creation | `T-CON-*`, `T-RPC-*` |
| Duplicate order submissions/idempotency | `T-CON-*`, `T-RPC-*` |
| Guest token expiry/revocation | `T-GST-*` (`BLK-003` for duration) |
| Full-settlement payment atomicity | `T-TXN-*`, `T-CON-*` (`BLK-001` for arithmetic) |
| Subscription grace/restricted | `T-SUB-*` |
| Historical record preservation | `T-HIS-*` |
