-- Security remediation foundation.
--
-- Adds:
--   * SHA-256 canonical fingerprint helper.
--   * DB-backed rate limiting for public Edge/waitlist operations.
--   * Organization operational-status checks (suspended/pending deletion).
--   * A dining-session context guard that rejects inserts against inactive
--     tables, branches, or organizations.
--   * Narrower helper execution grants and staff-only plan visibility.

create schema if not exists extensions;

do $$
declare
  v_pgcrypto_schema text;
begin
  if not exists (
    select 1 from pg_extension where extname = 'pgcrypto'
  ) then
    execute 'create extension pgcrypto with schema extensions';
  end if;

  select n.nspname
    into v_pgcrypto_schema
    from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_pgcrypto_schema is null then
    raise exception 'pgcrypto extension is not available';
  end if;

  execute format(
    $sql$
      create or replace function private.sha256_hex(p_value text)
      returns text
      language sql
      immutable
      security definer
      set search_path = %I, pg_catalog
      as $body$
        select encode(digest(coalesce(p_value, ''), 'sha256'), 'hex');
      $body$;
    $sql$,
    v_pgcrypto_schema
  );
end
$$;

revoke all on function private.sha256_hex(text) from public;

comment on function private.sha256_hex(text) is
  'SHA-256 hex digest used for canonical idempotency fingerprints.';

create table if not exists private.rate_limit_policies (
  policy_key text primary key,
  max_attempts integer not null,
  window_seconds integer not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  constraint rate_limit_policies_attempts_check check (max_attempts > 0),
  constraint rate_limit_policies_window_check check (window_seconds > 0)
);

create table if not exists private.rate_limit_buckets (
  policy_key text not null
    references private.rate_limit_policies (policy_key) on delete restrict,
  bucket_key text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (policy_key, bucket_key, window_start),
  constraint rate_limit_buckets_count_check check (count >= 0)
);

create index if not exists rate_limit_buckets_window_idx
  on private.rate_limit_buckets (window_start);

alter table private.rate_limit_policies enable row level security;
alter table private.rate_limit_buckets enable row level security;

insert into private.rate_limit_policies (
  policy_key,
  max_attempts,
  window_seconds
)
values
  ('guest_resolve_ip', 10, 60),
  ('guest_resolve_qr', 60, 60),
  ('guest_reconnect_ip', 60, 60),
  ('guest_session_ip', 120, 60),
  ('guest_token', 120, 60),
  ('waitlist_join_customer', 10, 3600)
on conflict (policy_key) do nothing;

create or replace function private.consume_rate_limit(
  p_policy text,
  p_bucket_suffix text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max integer;
  v_window_seconds integer;
  v_enabled boolean;
  v_window_start timestamptz;
  v_reset_at timestamptz;
  v_count integer;
  v_allowed boolean;
  v_retry_after integer;
begin
  if p_policy is null or length(p_policy) > 120 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Invalid rate-limit policy');
  end if;

  if p_bucket_suffix is null
     or length(p_bucket_suffix) = 0
     or length(p_bucket_suffix) > 512
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'Invalid rate-limit bucket');
  end if;

  select rlp.max_attempts, rlp.window_seconds, rlp.enabled
    into v_max, v_window_seconds, v_enabled
    from private.rate_limit_policies rlp
   where rlp.policy_key = p_policy;

  if not found or not v_enabled then
    perform private.raise_app_error(
      'SERVICE_UNAVAILABLE',
      'Rate-limit policy is not configured'
    );
  end if;

  v_window_start := to_timestamp(
    floor(extract(epoch from clock_timestamp()) / v_window_seconds)
    * v_window_seconds
  );
  v_reset_at := v_window_start + make_interval(secs => v_window_seconds);

  insert into private.rate_limit_buckets (
    policy_key,
    bucket_key,
    window_start,
    count
  )
  values (
    p_policy,
    p_bucket_suffix,
    v_window_start,
    1
  )
  on conflict (policy_key, bucket_key, window_start)
  do update set count = private.rate_limit_buckets.count + 1
  returning count into v_count;

  v_allowed := v_count <= v_max;
  v_retry_after := greatest(
    1,
    ceil(extract(epoch from (v_reset_at - clock_timestamp())))::integer
  );

  return jsonb_build_object(
    'allowed', v_allowed,
    'limit', v_max,
    'remaining', greatest(v_max - v_count, 0),
    'retryAfterSeconds', v_retry_after,
    'resetAt', v_reset_at
  );
end;
$$;

revoke all on function private.consume_rate_limit(text, text) from public;

create or replace function public.consume_rate_limit(
  p_policy text,
  p_bucket_suffix text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.consume_rate_limit(p_policy, p_bucket_suffix);
$$;

revoke all on function public.consume_rate_limit(text, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.consume_rate_limit(text, text) to service_role';
  end if;
end
$$;

comment on table private.rate_limit_policies is
  'Configurable server-side rate-limit policies. Defaults are security controls, not business rules.';

comment on function public.consume_rate_limit(text, text) is
  'Atomic DB-backed rate-limit consumption for Edge Functions. Service-role only.';

-- Organization operational status. Suspended and pending-deletion organizations
-- cannot perform new operational mutations. Historical RLS reads remain
-- available. Existing guest sessions are allowed for active and pending-deletion
-- organizations; suspended organizations reject guest tokens.
create or replace function authz.organization_is_operational(
  p_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organizations o
    where o.id = p_organization_id
      and o.status = 'active'
      and o.deleted_at is null
  )
  and not authz.org_is_restricted(p_organization_id);
$$;

create or replace function authz.organization_allows_guest_session(
  p_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organizations o
    where o.id = p_organization_id
      and o.status in ('active', 'pending_deletion')
      and o.deleted_at is null
  );
$$;

create or replace function authz.assert_org_operational(p_organization_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not authz.organization_is_operational(p_organization_id) then
    perform private.raise_app_error(
      'ORGANIZATION_NOT_OPERATIONAL',
      'The organization is suspended, pending deletion, or subscription-restricted'
    );
  end if;
end;
$$;

revoke all on function authz.organization_is_operational(uuid) from public;
revoke all on function authz.organization_allows_guest_session(uuid) from public;
revoke all on function authz.assert_org_operational(uuid) from public;

-- These helpers are not used by RLS policies and must not be executable by
-- arbitrary authenticated clients.
revoke execute on function authz.org_subscription_state(uuid) from authenticated;
revoke execute on function authz.org_is_restricted(uuid) from authenticated;

comment on function authz.organization_is_operational(uuid) is
  'True only for active, non-deleted organizations without a restricted subscription.';

comment on function authz.organization_allows_guest_session(uuid) is
  'Existing guest sessions may continue for active and pending-deletion organizations; suspended organizations are rejected.';

-- Plan catalog visibility is restricted to staff, not every authenticated user.
drop policy if exists plans_select_authenticated on public.plans;
drop policy if exists plan_entitlements_select_authenticated on public.plan_entitlements;

create policy plans_select_staff
  on public.plans for select to authenticated
  using (authz.current_staff_id() is not null);

create policy plan_entitlements_select_staff
  on public.plan_entitlements for select to authenticated
  using (authz.current_staff_id() is not null);

-- Defense-in-depth: sessions cannot be inserted against inactive tables,
-- branches, or organizations even if a concurrent state change races the RPC.
create or replace function private.guard_dining_session_context()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_status public.table_status;
  v_branch_status public.branch_status;
  v_org_status public.organization_status;
  v_org_deleted_at timestamptz;
begin
  select rt.status, b.status, o.status, o.deleted_at
    into v_table_status, v_branch_status, v_org_status, v_org_deleted_at
    from public.restaurant_tables rt
    join public.branches b
      on b.id = rt.branch_id
     and b.organization_id = rt.organization_id
    join public.organizations o
      on o.id = rt.organization_id
   where rt.id = new.table_id
     and rt.branch_id = new.branch_id
     and rt.organization_id = new.organization_id;

  if not found
     or v_table_status <> 'active'
     or v_branch_status <> 'active'
     or v_org_status <> 'active'
     or v_org_deleted_at is not null
  then
    perform private.raise_app_error(
      'TABLE_QR_INVALID',
      'Table, branch, or organization is not active'
    );
  end if;

  return new;
end;
$$;

revoke all on function private.guard_dining_session_context() from public;

create trigger dining_sessions_guard_context
  before insert on public.dining_sessions
  for each row execute function private.guard_dining_session_context();

comment on function private.guard_dining_session_context() is
  'Rejects dining-session inserts when the table, branch, or organization is inactive.';
