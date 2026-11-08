-- Deterministic, schema-independent helpers for fixtures and tests.

-- Stable UUID derived from a label. Useful before concrete tables exist.
create or replace function tests.uuid_for(p_label text)
returns uuid
language sql
immutable
strict
as $$
  select (
    substr(md5(p_label), 1, 8) || '-' ||
    substr(md5(p_label), 9, 4) || '-4' ||
    substr(md5(p_label), 14, 3) || '-a' ||
    substr(md5(p_label), 18, 3) || '-' ||
    substr(md5(p_label), 21, 12)
  )::uuid;
$$;

-- Optional per-run marker. Set with:
--   select set_config('app.test_run_id', 'run-...', false);
create or replace function tests.run_id()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('app.test_run_id', true), ''), 'local');
$$;

grant execute on function tests.uuid_for(text) to anon, authenticated, service_role;
grant execute on function tests.run_id() to anon, authenticated, service_role;
