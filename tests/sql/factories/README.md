# Test factories

Factories are schema-dependent and therefore blocked until Agent 1's database
foundation is merged. When it lands, add SQL factory functions here using the
`tests.make_*` naming convention.

Rules:

- Deterministic IDs via `tests.uuid_for('label')`.
- Never reference `supabase/seed.sql` IDs or data.
- Every factory must be independent of development seed data.
- Keep factories additive and in new files; Agent 3 owns this directory.
