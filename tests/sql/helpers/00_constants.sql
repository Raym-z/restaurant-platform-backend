-- Test-only schema. Applied at runtime by scripts/prepare-test-db.mjs.
-- It is never a Supabase migration and never ships to a remote environment.

create schema if not exists tests;

comment on schema tests is
  'Runtime-only helpers and fixtures for local database tests. Never applied as a migration.';
