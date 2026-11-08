# Testing Strategy

## 1. Purpose

This document defines how the shared backend is validated. Tests exercise the
real database, RLS policies, RPCs, Edge Functions, and contracts. Agent 3 owns
test infrastructure and does not reimplement business logic owned by Agent 1 or
Agent 2.

## 2. Ownership boundaries

| Owner | Responsibility |
|---|---|
| Agent 1 | Schema, tables, enums, constraints, indexes, schema foundation migrations |
| Agent 2 | RLS policies, authorization helpers, RPCs, Edge Functions, shared contracts, service migrations |
| Agent 3 | Test tooling, fixtures, test suites, local diagnostics, CI, static validation |

Rules:

- Agent 1's database foundation must merge before Agent 2 creates schema-dependent
  migrations.
- Agent 3 never creates application schema migrations.
- Test helpers and fixtures live under `tests/` and are applied at runtime with
  `supabase db query`/`pg`; they are never migrations.
- `package.json` test tooling is owned by Agent 3. Runtime dependencies are proposed
  by Agent 2. Only one agent changes `package-lock.json` at a time.

## 3. Five initial roles

The authorization model under test is exactly:

- Owner (organization-wide)
- Admin (organization-wide or explicitly branch-scoped)
- Manager (specific branch per assignment)
- Cashier (specific branch per assignment)
- Kitchen Staff (specific branch per assignment)

Host/Queue Staff is not part of the initial release and must not appear in
fixtures, seed data, or tests. Granular permission mappings beyond documented
role scope are blocked (`BLK-005`).

## 4. Test layers and tools

| Layer | Tool | Scope |
|---|---|---|
| Static/guard | Node + git | Migration governance, secrets, blockers, manifests, typecheck |
| Catalog hygiene | pgTAP | RLS presence, private grants, types, SECURITY DEFINER safety |
| Constraints | pgTAP | FKs, composite tenant FKs, partial unique indexes, checks |
| RLS | pgTAP | Real anon/authenticated roles, JWT claims, permitted + denied |
| RPC rules | pgTAP | Validation, transitions, atomicity, audit, idempotency |
| Concurrency | Node + `pg` | Independent connections, races, invariants |
| Contract | Vitest + Zod | Request/response schemas, error catalog, envelopes |
| Edge | Deno + HTTP | Trusted orchestration, token flows, leakage |
| E2E smoke | Node | Guest dining lifecycle on the local stack |

## 5. Local commands

```powershell
npm run doctor          # Docker, Supabase, ports, config diagnostics
npm run test:static     # no Docker required
npm run test:db         # start stack, reset --no-seed, helpers, pgTAP
npm run test:db:fast    # skip reset for iteration
npm run test:integration
npm run test:edge
npm run test:all        # complete local suite
```

`test:all` is the single documented command for the complete local suite.

## 6. Local environment guard

Before any operation that starts, resets, queries, or truncates a database:

1. `supabase/config.toml` must exist and be readable (Agent 1 owns it).
2. API/DB endpoints must resolve to `127.0.0.1`, `localhost`, or `::1`.
3. `SUPABASE_URL`, `SUPABASE_DB_URL`, `DATABASE_URL`, and `PGHOST` must not point
   off-host; the guard fails instead of discarding them.
4. Test keys come from `supabase status -o env`; there is no remote fallback.
5. `--remote`, `--linked`, and `--project-ref` are rejected.
6. `NODE_ENV=production` is rejected.
7. Destructive scripts (`db reset`, truncation, concurrency cleanup) run only after
   the guard passes.

Static checks do not need Docker or `config.toml`.

## 7. RLS testing requirements

- Use the real `anon` and `authenticated` database roles.
- Set realistic JWT claims (`sub`, `role`, `aud`, `iss`, `iat`, `exp`).
- Never use `postgres` or `service_role` to prove RLS isolation. They are limited
  to setup/teardown and privileged-path tests.
- For each table and operation, test both permitted and denied access:
  anon, same-org/assigned-branch staff, same-org/unassigned-branch staff,
  other-org staff, customer own/other.
- Test SELECT, INSERT, UPDATE, and DELETE independently, plus RPC `EXECUTE` grants.
- Forged organization/branch/session IDs must not grant access and must not leak
  resource existence.

`tests.authenticate_as()` switches to a real role and sets claims; `tests.clear_auth()`
restores the session role. Only the test runner may call `authenticate_as`.

## 8. SECURITY DEFINER testing

Tested independently of RLS:

- `prosecdef` is set intentionally.
- An explicit safe `search_path` exists.
- Execute grants are restricted.
- The function validates caller identity, tenant scope, token state, and resource
  state itself; denial does not depend on table RLS.
- Anonymous/forged callers cannot use it as an RLS bypass.

## 9. Fixtures and seed independence

- Test runs use `supabase db reset --no-seed`.
- Factories create all required state.
- Tests never reference `supabase/seed.sql` IDs or rows.
- A separate CI job validates that seed still applies, but tests must pass without it.
- Deterministic IDs come from `tests.uuid_for('label')`; runtime isolation uses
  fresh UUIDs for concurrency.
- One known raw guest token may exist per scenario; only its hash is stored and the
  raw value is never printed or uploaded.

## 10. Concurrency isolation and cleanup

- One independent `pg` connection per concurrent actor; no shared pool.
- Isolated fixture namespaces per test/run.
- Clients close and fixtures clean up in `finally`/`afterEach`/`afterAll`.
- Suite-level reset before and after concurrency runs, even on failure.
- Failed tests cannot contaminate later runs; a run marker distinguishes stale data.
- Tests assert final invariants, not timing, and are repeated to detect races.

## 11. Blocked business rules

`docs/test-blockers.md` tracks BLK-001 through BLK-008. Tests must not assert
unapproved behavior. A skip without a `BLK-###` reference fails
`npm run verify:blockers`.

## 12. RLS coverage manifest

`tests/registry/rls-coverage.json` maps every RLS-enabled public table and
operation to `T-RLS-###` test IDs. `npm run verify:rls` checks structure; the
database CI job compares the manifest with `pg_class`/`pg_policies`. While the
manifest is empty, enforcement is deferred until Agent 2 lands policies.

## 13. CI

| Job | Docker | Purpose |
|---|---|---|
| `static` | No | Tooling, migrations, secrets, blockers, manifests, typecheck, contract unit tests |
| `database` | Yes | Doctor, stack, reset without seed, lint, pgTAP, integration/concurrency, RLS coverage |
| `seed-validation` | Yes | `db reset` with seed; proves migrations and seed still apply |
| `edge-contracts` | Yes | Contract tests, Deno unit tests, guest HTTP integration |
| `report` | No | Aggregate required checks and redacted artifacts |

No repository secrets are required. Artifacts redact JWTs, service-role keys, raw
guest tokens, and credential-bearing URLs.

## 14. Migration validation

- Filename format `YYYYMMDDHHMMSS_description.sql`, strictly increasing.
- Merged migrations are immutable; edits/deletions fail.
- Destructive DDL requires an explicit approval marker.
- `DISABLE ROW LEVEL SECURITY` fails.
- `SECURITY DEFINER` without `search_path` fails.
- Grants of `private` objects to `anon`/`authenticated`/`public` fail.
- Clean apply, lint, and later an upgrade baseline are enforced.
- Generated-type drift is checked once Agent 2 commits a types file.

## 15. Definition of done for a feature

1. Approved behavior is documented.
2. Migration/RLS/RPC is merged by its owner.
3. Positive and negative tests exist.
4. Static, database, and relevant integration suites pass.
5. Blocked rules are not asserted or are explicitly marked.
6. Docs/traceability are updated.

## 16. Ownership and sequencing

Agent 3 only modifies:

- `tests/**`
- `scripts/**`
- `docs/testing-strategy.md`, `docs/local-testing.md`,
  `docs/test-traceability.md`, `docs/test-blockers.md`
- `.github/workflows/**`
- test tooling in `package.json` / `package-lock.json` (single-writer protocol)
- `.nvmrc`, `.env.test.example`, `tsconfig.test.json`

Agent 3 never modifies:

- `supabase/migrations/**` (Agent 1 schema; Agent 2 service migrations)
- `supabase/config.toml` (Agent 1)
- `supabase/seed.sql` (Agent 1)
- `supabase/functions/**` (Agent 2)
- `src/contracts/**` (Agent 2)

Sequencing:

1. Independent tooling, diagnostics, static checks, CI (this change).
2. Agent 1 database foundation merges.
3. Migration, catalog, and constraint tests.
4. Factories/scenarios and seed-independence checks.
5. Agent 2 RLS/authorization migrations merge; RLS matrix and SECURITY
   DEFINER tests.
6. Agent 2 RPC/service migrations merge; RPC and concurrency tests.
7. Agent 2 Edge Functions and contracts merge; Edge and contract tests.
8. Subscription, historical-preservation, E2E smoke, coverage enforcement.

Merge gates are enforced by review: Agent 2 must not create schema-dependent
migrations before Agent 1's foundation, and Agent 3 must not edit their files to
make tests pass.

See `docs/test-traceability.md` for the requirement-to-test map.
