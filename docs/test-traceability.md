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
