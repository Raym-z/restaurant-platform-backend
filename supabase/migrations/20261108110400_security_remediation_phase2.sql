-- Security remediation Phase 2.
--
-- approved-destructive-change: security-remediation-phase-2-rate-limit-retention
--
-- Fixes:
--   * Organization status locking (suspension/pending-deletion races).
--   * Missing subscription records fail closed as restricted.
--   * Consistent subscription-restricted error codes.
--   * Session-row locking for token issuance vs session-wide revocation.
--   * Privacy-preserving rate-limit bucket retention/cleanup.
--   * Platform-admin plan visibility.

create or replace function authz.org_subscription_state(p_organization_id uuid)
returns public.subscription_state
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select s.state
      from public.subscriptions s
      where s.organization_id = p_organization_id
    ),
    'restricted'::public.subscription_state
  );
$$;

comment on function authz.org_subscription_state(uuid) is
  'Missing subscription records fail closed as restricted.';

drop policy if exists plans_select_platform_admin on public.plans;
drop policy if exists plan_entitlements_select_platform_admin on public.plan_entitlements;

create policy plans_select_platform_admin
  on public.plans for select to authenticated
  using (authz.is_platform_admin());

create policy plan_entitlements_select_platform_admin
  on public.plan_entitlements for select to authenticated
  using (authz.is_platform_admin());

create or replace function authz.assert_org_operational(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Serialize operational mutations with suspension/pending-deletion and
  -- subscription-state changes.
  perform 1
    from public.organizations o
   where o.id = p_organization_id
   for update;

  if not exists (
    select 1
    from public.organizations o
    where o.id = p_organization_id
      and o.status = 'active'
      and o.deleted_at is null
  ) then
    perform private.raise_app_error(
      'ORGANIZATION_NOT_OPERATIONAL',
      'The organization is suspended, pending deletion, or deleted'
    );
  end if;

  if authz.org_is_restricted(p_organization_id) then
    perform private.raise_app_error(
      'SUBSCRIPTION_RESTRICTED',
      'The organization subscription is restricted'
    );
  end if;
end;
$$;

create or replace function authz.assert_org_can_administer(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform authz.assert_org_operational(p_organization_id);
end;
$$;

revoke all on function authz.assert_org_operational(uuid) from public;
revoke all on function authz.assert_org_can_administer(uuid) from public;

-- Bound rate-limit bucket keys and provide a scheduled retention hook. The
-- cleanup function is service-role only; schedule it with pg_cron or an
-- external scheduler (recommended hourly/daily). Retention is independent of
-- guest-token TTL/cleanup (BLK-003).
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
     or length(p_bucket_suffix) > 128
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

create or replace function private.cleanup_rate_limit_buckets(
  p_retention_seconds integer default 86400
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  if p_retention_seconds < 60 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Rate-limit retention must be at least 60 seconds'
    );
  end if;

  delete from private.rate_limit_buckets
   where window_start < clock_timestamp() - make_interval(secs => p_retention_seconds);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

create or replace function public.cleanup_rate_limit_buckets(
  p_retention_seconds integer default 86400
)
returns integer
language sql
security definer
set search_path = ''
as $$
  select private.cleanup_rate_limit_buckets(p_retention_seconds);
$$;

revoke all on function private.cleanup_rate_limit_buckets(integer) from public;
revoke all on function public.cleanup_rate_limit_buckets(integer) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.cleanup_rate_limit_buckets(integer) to service_role';
  end if;
end
$$;

comment on function public.cleanup_rate_limit_buckets(integer) is
  'Deletes rate-limit buckets older than the retention interval. Service-role only; schedule separately.';

-- Organization/branch/table operations acquire the organization lock first,
-- then branch/table locks, matching session resolution.
create or replace function public.create_table(
  p_branch_id uuid,
  p_label text,
  p_capacity integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_org_id uuid;
  v_table_id uuid;
  v_qr_public_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null or v_branch_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_org_can_administer(v_org_id);

  perform 1
    from public.branches b
   where b.id = p_branch_id
   for update;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);

  if nullif(btrim(p_label), '') is null or p_capacity <= 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Table label and capacity are required');
  end if;

  insert into public.restaurant_tables (
    organization_id, branch_id, label, capacity
  )
  values (v_org_id, p_branch_id, btrim(p_label), p_capacity)
  returning id into v_table_id;

  insert into public.table_qr_identifiers (
    organization_id, branch_id, table_id
  )
  values (v_org_id, p_branch_id, v_table_id)
  returning public_id into v_qr_public_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'table.created', 'restaurant_table', v_table_id, null,
    jsonb_build_object('label', btrim(p_label), 'capacity', p_capacity)
  );

  return jsonb_build_object(
    'tableId', v_table_id,
    'branchId', p_branch_id,
    'qrPublicId', v_qr_public_id
  );
end;
$$;

create or replace function public.deactivate_branch(
  p_branch_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();

  select b.organization_id into v_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_org_id is null or v_org_id is distinct from authz.current_organization_id() then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_org_can_administer(v_org_id);

  perform 1
    from public.branches b
   where b.id = p_branch_id
   for update;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin']::text[]);

  if exists (
    select 1
    from public.dining_sessions ds
    where ds.branch_id = p_branch_id
      and ds.status = 'active'
  ) then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'A branch with an active dining session cannot be deactivated'
    );
  end if;

  update public.branches
     set status = 'inactive',
         deactivated_at = now()
   where id = p_branch_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'branch.deactivated', 'branch', p_branch_id,
    nullif(btrim(p_reason), ''), '{}'::jsonb
  );

  return jsonb_build_object('branchId', p_branch_id, 'status', 'inactive');
end;
$$;

create or replace function public.deactivate_table(
  p_table_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_table_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_org_can_administer(v_org_id);

  perform 1
    from public.restaurant_tables rt
   where rt.id = p_table_id
   for update;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);

  if exists (
    select 1
    from public.dining_sessions ds
    where ds.table_id = p_table_id
      and ds.status = 'active'
  ) then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'A table with an active dining session cannot be deactivated'
    );
  end if;

  update public.restaurant_tables
     set status = 'inactive',
         deactivated_at = now()
   where id = p_table_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'table.deactivated', 'restaurant_table', p_table_id,
    nullif(btrim(p_reason), ''), '{}'::jsonb
  );

  return jsonb_build_object('tableId', p_table_id, 'status', 'inactive');
end;
$$;

create or replace function public.regenerate_table_qr(p_table_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_table_org_id uuid;
  v_qr_public_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_org_can_administer(v_org_id);

  perform 1
    from public.restaurant_tables rt
   where rt.id = p_table_id
   for update;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);

  update public.table_qr_identifiers
     set revoked_at = now()
   where table_id = p_table_id
     and revoked_at is null;

  insert into public.table_qr_identifiers (
    organization_id, branch_id, table_id
  )
  values (v_org_id, v_branch_id, p_table_id)
  returning public_id into v_qr_public_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'table.qr_regenerated', 'restaurant_table', p_table_id, null,
    jsonb_build_object('qr_public_id', v_qr_public_id)
  );

  return jsonb_build_object('tableId', p_table_id, 'qrPublicId', v_qr_public_id);
end;
$$;

create or replace function public.resolve_or_create_dining_session(
  p_qr_public_id uuid,
  p_token_hash_hex text,
  p_device_label text default null,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_branch_id uuid;
  v_org_id uuid;
  v_table_label text;
  v_branch_name text;
  v_timezone text;
  v_currency_code text;
  v_session_id uuid;
  v_session_status public.dining_session_status;
  v_opened_at timestamptz;
  v_token_id uuid;
  v_session_created boolean := false;
begin
  if auth.role() is distinct from 'service_role' then
    perform private.raise_app_error('PERMISSION_DENIED', 'Service role is required');
  end if;

  if p_token_hash_hex is null or p_token_hash_hex !~ '^[0-9a-f]{64}$' then
    perform private.raise_app_error('VALIDATION_ERROR', 'Token hash must be 64 lowercase hex characters');
  end if;

  if p_expires_at is null or p_expires_at <= now() then
    perform private.raise_app_error('VALIDATION_ERROR', 'Guest token expiry must be in the future');
  end if;

  select tqr.table_id, tqr.branch_id, tqr.organization_id
    into v_table_id, v_branch_id, v_org_id
    from public.table_qr_identifiers tqr
    join public.restaurant_tables t
      on t.id = tqr.table_id
     and t.branch_id = tqr.branch_id
     and t.organization_id = tqr.organization_id
    join public.branches b
      on b.id = tqr.branch_id
     and b.organization_id = tqr.organization_id
   where tqr.public_id = p_qr_public_id
   limit 1;

  if v_table_id is null then
    perform private.raise_app_error('TABLE_QR_INVALID', 'Table QR is invalid or inactive');
  end if;

  -- Lock order: organization -> branch -> table -> dining_session.
  perform 1
    from public.organizations o
   where o.id = v_org_id
   for update;

  if not exists (
    select 1
    from public.organizations o
    where o.id = v_org_id
      and o.status = 'active'
      and o.deleted_at is null
  ) then
    perform private.raise_app_error(
      'ORGANIZATION_NOT_OPERATIONAL',
      'The organization is not operational'
    );
  end if;

  if authz.org_is_restricted(v_org_id) then
    perform private.raise_app_error(
      'SUBSCRIPTION_RESTRICTED',
      'New guest sessions and tokens are blocked while the organization subscription is restricted'
    );
  end if;

  perform 1
    from public.branches b
   where b.id = v_branch_id
   for update;

  perform 1
    from public.restaurant_tables rt
   where rt.id = v_table_id
   for update;

  select tqr.table_id, tqr.branch_id, tqr.organization_id,
         t.label, b.name, b.timezone, o.default_currency_code
    into v_table_id, v_branch_id, v_org_id,
         v_table_label, v_branch_name, v_timezone, v_currency_code
    from public.table_qr_identifiers tqr
    join public.restaurant_tables t
      on t.id = tqr.table_id
     and t.branch_id = tqr.branch_id
     and t.organization_id = tqr.organization_id
    join public.branches b
      on b.id = tqr.branch_id
     and b.organization_id = tqr.organization_id
    join public.organizations o
      on o.id = tqr.organization_id
   where tqr.public_id = p_qr_public_id
     and tqr.revoked_at is null
     and t.status = 'active'
     and b.status = 'active'
     and o.status = 'active'
     and o.deleted_at is null;

  if v_table_id is null then
    perform private.raise_app_error('TABLE_QR_INVALID', 'Table QR is invalid or inactive');
  end if;

  select ds.id, ds.status, ds.opened_at
    into v_session_id, v_session_status, v_opened_at
    from public.dining_sessions ds
   where ds.table_id = v_table_id
     and ds.status = 'active'
   limit 1;

  if v_session_id is null then
    insert into public.dining_sessions (
      organization_id, branch_id, table_id
    )
    values (v_org_id, v_branch_id, v_table_id)
    returning id, status, opened_at
    into v_session_id, v_session_status, v_opened_at;

    v_session_created := true;
  end if;

  -- Shared session lock for token issuance vs session-wide revocation.
  select ds.status
    into v_session_status
    from public.dining_sessions ds
   where ds.id = v_session_id
   for update;

  if v_session_status <> 'active' then
    perform private.raise_app_error('SESSION_NOT_ACTIVE', 'The dining session is not active');
  end if;

  begin
    insert into private.guest_tokens (
      organization_id,
      branch_id,
      dining_session_id,
      token_hash,
      issued_at,
      expires_at,
      device_label
    )
    values (
      v_org_id,
      v_branch_id,
      v_session_id,
      decode(p_token_hash_hex, 'hex'),
      clock_timestamp(),
      p_expires_at,
      nullif(btrim(p_device_label), '')
    )
    returning id into v_token_id;
  exception
    when unique_violation then
      perform private.raise_app_error('RESOURCE_CONFLICT', 'Guest token hash already exists');
  end;

  if v_session_created then
    perform private.audit_write(
      'guest', null, null, v_org_id, v_branch_id,
      'dining_session.created', 'dining_session', v_session_id, null,
      jsonb_build_object('table_id', v_table_id)
    );
  end if;

  perform private.audit_write(
    'guest', null, null, v_org_id, v_branch_id,
    'guest_token.issued', 'guest_token', v_token_id, null,
    jsonb_build_object('session_id', v_session_id, 'expires_at', p_expires_at)
  );

  return jsonb_build_object(
    'sessionId', v_session_id,
    'organizationId', v_org_id,
    'branchId', v_branch_id,
    'tableId', v_table_id,
    'tableLabel', v_table_label,
    'branchName', v_branch_name,
    'timezone', v_timezone,
    'currency', v_currency_code,
    'status', v_session_status,
    'openedAt', v_opened_at,
    'tokenExpiresAt', p_expires_at
  );
end;
$$;

create or replace function public.validate_guest_token(p_token_hash_hex text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token_id uuid;
  v_session_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_table_id uuid;
  v_table_label text;
  v_branch_name text;
  v_timezone text;
  v_currency_code text;
  v_session_status public.dining_session_status;
  v_opened_at timestamptz;
  v_expires_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' then
    perform private.raise_app_error('PERMISSION_DENIED', 'Service role is required');
  end if;

  if p_token_hash_hex is null or p_token_hash_hex !~ '^[0-9a-f]{64}$' then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid');
  end if;

  select gt.id, gt.dining_session_id, gt.organization_id, gt.branch_id,
         gt.expires_at, ds.table_id, rt.label, b.name, b.timezone,
         o.default_currency_code, ds.status, ds.opened_at
    into v_token_id, v_session_id, v_org_id, v_branch_id,
         v_expires_at, v_table_id, v_table_label, v_branch_name, v_timezone,
         v_currency_code, v_session_status, v_opened_at
    from private.guest_tokens gt
    join public.dining_sessions ds
      on ds.id = gt.dining_session_id
     and ds.branch_id = gt.branch_id
     and ds.organization_id = gt.organization_id
    join public.restaurant_tables rt
      on rt.id = ds.table_id
     and rt.branch_id = ds.branch_id
     and rt.organization_id = ds.organization_id
    join public.branches b
      on b.id = ds.branch_id
     and b.organization_id = ds.organization_id
    join public.organizations o
      on o.id = ds.organization_id
   where gt.token_hash = decode(p_token_hash_hex, 'hex')
     and gt.revoked_at is null
     and gt.expires_at > now()
     and ds.status = 'active'
     and rt.status = 'active'
     and b.status = 'active'
   limit 1;

  if v_token_id is null then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid or expired');
  end if;

  -- Share-lock the organization so suspension/pending-deletion waits for
  -- in-flight reads, while concurrent guest reads remain possible.
  perform 1
    from public.organizations o
   where o.id = v_org_id
   for share;

  if not authz.organization_allows_guest_session(v_org_id) then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid or expired');
  end if;

  update private.guest_tokens
     set last_used_at = now()
   where id = v_token_id;

  return jsonb_build_object(
    'sessionId', v_session_id,
    'organizationId', v_org_id,
    'branchId', v_branch_id,
    'tableId', v_table_id,
    'tableLabel', v_table_label,
    'branchName', v_branch_name,
    'timezone', v_timezone,
    'currency', v_currency_code,
    'status', v_session_status,
    'openedAt', v_opened_at,
    'tokenExpiresAt', v_expires_at
  );
end;
$$;

create or replace function public.suspend_organization(
  p_organization_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_platform_admin_id uuid;
  v_previous_status public.organization_status;
begin
  select pa.id into v_platform_admin_id
    from public.platform_admins pa
   where pa.auth_user_id = auth.uid()
     and pa.revoked_at is null;

  if v_platform_admin_id is null then
    perform private.raise_app_error('PLATFORM_ACCESS_DENIED', 'Platform administrator access is required');
  end if;

  select o.status into v_previous_status
    from public.organizations o
   where o.id = p_organization_id
   for update;

  if v_previous_status is null then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  update public.organizations
     set status = 'suspended'
   where id = p_organization_id;

  perform private.audit_write(
    'platform_admin', v_platform_admin_id, null, p_organization_id, null,
    'platform.organization_suspended', 'organization', p_organization_id,
    nullif(btrim(p_reason), ''), jsonb_build_object('previous_status', v_previous_status)
  );

  return jsonb_build_object('organizationId', p_organization_id, 'status', 'suspended');
end;
$$;

create or replace function public.reactivate_organization(
  p_organization_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_platform_admin_id uuid;
  v_previous_status public.organization_status;
begin
  select pa.id into v_platform_admin_id
    from public.platform_admins pa
   where pa.auth_user_id = auth.uid()
     and pa.revoked_at is null;

  if v_platform_admin_id is null then
    perform private.raise_app_error('PLATFORM_ACCESS_DENIED', 'Platform administrator access is required');
  end if;

  select o.status into v_previous_status
    from public.organizations o
   where o.id = p_organization_id
   for update;

  if v_previous_status is null then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  update public.organizations
     set status = 'active'
   where id = p_organization_id;

  perform private.audit_write(
    'platform_admin', v_platform_admin_id, null, p_organization_id, null,
    'platform.organization_reactivated', 'organization', p_organization_id,
    nullif(btrim(p_reason), ''), jsonb_build_object('previous_status', v_previous_status)
  );

  return jsonb_build_object('organizationId', p_organization_id, 'status', 'active');
end;
$$;

create or replace function public.revoke_session_guest_tokens(
  p_session_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_session_org_id uuid;
  v_branch_id uuid;
  v_revoked_count integer;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select ds.organization_id, ds.branch_id
    into v_session_org_id, v_branch_id
    from public.dining_sessions ds
   where ds.id = p_session_id;

  if v_session_org_id is null or v_session_org_id is distinct from v_org_id then
    perform private.raise_app_error('GUEST_SESSION_NOT_FOUND', 'Guest session was not found');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);

  -- Shared session lock with resolve_or_create_dining_session.
  perform 1
    from public.dining_sessions ds
   where ds.id = p_session_id
   for update;

  update private.guest_tokens
     set revoked_at = now()
   where dining_session_id = p_session_id
     and revoked_at is null;

  get diagnostics v_revoked_count = row_count;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'guest_token.session_revoked', 'dining_session', p_session_id,
    nullif(btrim(p_reason), ''), jsonb_build_object('revoked_count', v_revoked_count)
  );

  return jsonb_build_object(
    'sessionId', p_session_id,
    'revokedCount', v_revoked_count
  );
end;
$$;
