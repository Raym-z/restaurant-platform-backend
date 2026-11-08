-- Harness smoke test: proves the runtime test schema and auth simulation work.
-- This file intentionally depends only on Supabase's built-in auth.uid() and the
-- Agent 3 test helpers, not on application tables owned by Agent 1.

begin;

select plan(5);

select has_schema('tests', 'runtime test helper schema exists');

select has_function(
  'tests',
  'authenticate_as',
  array['uuid', 'jsonb', 'text'],
  'authenticate_as helper exists'
);

select tests.authenticate_as(
  '00000000-0000-0000-0000-000000000001'::uuid,
  '{}'::jsonb,
  'authenticated'
);

select is(
  current_user::text,
  'authenticated',
  'the real authenticated database role is active'
);

select is(
  auth.uid(),
  '00000000-0000-0000-0000-000000000001'::uuid,
  'auth.uid() resolves from realistic JWT claims'
);

select tests.clear_auth();

select is(
  current_user::text,
  session_user::text,
  'clear_auth() restores the session role'
);

select * from finish();

rollback;
