# Test Blockers

Tests must never encode unapproved business rules. Each blocked area is tracked
here. A skipped test must reference a `BLK-###` entry and the reason; otherwise
`npm run verify:blockers` fails.

| ID | Blocked area | Why blocked | Affected suites |
|---|---|---|---|
| BLK-001 | Exact billing arithmetic: tax base, tax/service ordering, compounding, inclusivity, discount scope/stacking, rounding | The bill-calculation contract is not approved | `250_rpc_billing`, `260_rpc_payment`, billing integration |
| BLK-002 | Item-level preparation transitions, cancellation effects on bills, KDS notification behavior | M3 approved the order-level transition matrix; item-level and billing/KDS effects remain deferred | `240_rpc_orders`, order integration |
| BLK-003 | Guest token expiry duration, rotation, cleanup schedule | Expiry policy is not approved | `130_rls_guest_session`, guest integration |
| BLK-004 | Waitlist behavior under subscription restriction; notification timing and no-show thresholds | Queue workflow/restriction rules are not specified | `270_rpc_waitlist`, `280_rpc_subscription` |
| BLK-005 | Granular role-to-permission mappings beyond documented role scope | The detailed permission matrix is not approved | `210_rpc_staff_access`, authorization tests |
| BLK-006 | Bill reopen/void/replacement authorization, transitions, and replacement linkage | Correction workflow is not approved | `250_rpc_billing` |
| BLK-007 | Refund, void, correction, and reconciliation workflows | Financial correction workflow is not approved | `260_rpc_payment` |
| BLK-008 | Realtime channel names, publication payloads, and subscription filtering | Realtime configuration is not approved | Realtime authorization tests |

## Rules

1. Do not add an assertion for a blocked rule.
2. If a test skeleton must exist, mark it `skip`/`todo` with a `BLK-###` reference.
3. When a decision is approved, remove the blocker entry and unskip the test in the
   same coordinated change.
4. Tests that remain valid despite a blocked rule (for example, integer minor units
   and `change = received - due`) may still run.

## Unblocked invariants that remain testable

- Money uses integer minor units plus an explicit currency code; no floating point.
- Cash payment is one full-settlement payment in the initial release.
- A dining session closes only at a zero outstanding balance.
- Token revocation on session close is mandatory.
- Completed orders and settled payments are historical records.
- Fulfillment is independent of payment state.
- An order is Served only when all non-cancelled items are Served.
- One active dining session per table and one active queue entry per customer per
  branch.
