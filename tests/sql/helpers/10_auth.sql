-- Authentication simulation for RLS tests.
--
-- Rules:
--   * Use real anon/authenticated/service_role database roles.
--   * Never prove RLS isolation as postgres or service_role.
--   * Claims are set inside the current transaction and cleared by tests.clear_auth().

create or replace function tests.authenticate_as(
  p_user_id uuid,
  p_claims jsonb default '{}'::jsonb,
  p_role text default 'authenticated'
)
returns void
language plpgsql
as $$
declare
  v_claims jsonb;
  v_now bigint := extract(epoch from now())::bigint;
begin
  if p_role not in ('anon', 'authenticated', 'service_role') then
    raise exception 'Unsupported test role: %', p_role
      using hint = 'Use anon, authenticated, or service_role.';
  end if;

  v_claims := jsonb_build_object(
    'sub', p_user_id,
    'role', p_role,
    'aud', 'authenticated',
    'iss', 'http://127.0.0.1:54321/auth/v1',
    'iat', v_now,
    'exp', v_now + 3600
  ) || coalesce(p_claims, '{}'::jsonb);

  perform set_config('request.jwt.claims', v_claims::text, true);
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('request.jwt.claim.role', p_role, true);

  execute format('set local role %I', p_role);
end;
$$;

create or replace function tests.clear_auth()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  execute 'reset role';
end;
$$;

create or replace function tests.authenticate_as_anon()
returns void
language plpgsql
as $$
begin
  perform tests.authenticate_as(
    '00000000-0000-0000-0000-000000000000'::uuid,
    '{}'::jsonb,
    'anon'
  );
end;
$$;

revoke all on schema tests from public;
grant usage on schema tests to anon, authenticated, service_role;

-- Only the test runner (postgres) may switch identities.
revoke all on function tests.authenticate_as(uuid, jsonb, text) from public;
revoke all on function tests.authenticate_as_anon() from public;

-- A test that is currently authenticated must be able to reset itself.
grant execute on function tests.clear_auth() to anon, authenticated, service_role;
