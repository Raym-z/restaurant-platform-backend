# Integration test setup

This directory holds the Node/TypeScript harness for integration and concurrency
tests. It is intentionally independent of development seed data.

- `env.ts` — resolves and validates the local database URL (loopback only).
- `db.ts` — creates independent `pg` clients for each concurrent actor.
- `cleanup.ts` — explicit teardown helpers; call these in `finally`/`afterEach`.
- `smoke.test.ts` — verifies the harness can connect to the local database.

Rules:

1. Each concurrent actor gets its own connection.
2. Fixtures are isolated per test/run.
3. Cleanup runs even when an assertion fails.
4. Never point these tests at a remote database.
