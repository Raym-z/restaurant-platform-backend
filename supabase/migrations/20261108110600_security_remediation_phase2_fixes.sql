-- Security remediation Phase 2 corrections.


-- Security remediation Phase 2 corrections.
--
-- approved-destructive-change: security-remediation-phase-2-rate-limit-retention
--
-- Fixes:
--   * Advisory org locks instead of organization-row locks.
--   * Safe rate-limit cleanup based on policy window expiry.
--   * Waitlist org -> entry lock order.
--   * add_walk_in cross-tenant normalization.
--   * Customer UUID hashing in rate-limit buckets.
--   * Token validation share-locks the dining session against revocation.

create or replace function authz.acquire_org_shared_lock(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock_shared(
    hashtextextended('organization:' || p_organization_id::text, 0)
  );
end;
$$;

create or replace function authz.acquire_org_exclusive_lock(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('organization:' || p_organization_id::text, 0)
  );
end;
$$;

revoke all on function authz.acquire_org_shared_lock(uuid) from public;
revoke all on function authz.acquire_org_exclusive_lock(uuid) from public;

create or replace function authz.assert_org_operational(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform authz.acquire_org_shared_lock(p_organization_id);

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

revoke all on function authz.assert_org_operational(uuid) from public;

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

  select gt.id, gt.dining_session_id, gt.organization_id
    into v_token_id, v_session_id, v_org_id
    from private.guest_tokens gt
   where gt.token_hash = decode(p_token_hash_hex, 'hex');

  if v_session_id is null then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid or expired');
  end if;

  -- Shared advisory org lock permits concurrent reads but blocks suspension.
  perform authz.acquire_org_shared_lock(v_org_id);

  -- Share-lock the dining session so session-wide revocation and token
  -- validation serialize. Revocation takes the exclusive session lock.
  perform 1
    from public.dining_sessions ds
   where ds.id = v_session_id
   for share;

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
   where gt.id = v_token_id
     and gt.revoked_at is null
     and gt.expires_at > now()
     and ds.status = 'active'
     and rt.status = 'active'
     and b.status = 'active'
     and authz.organization_allows_guest_session(o.id)
   limit 1;

  if v_token_id is null then
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

create or replace function public.update_waitlist_status(
  p_entry_id uuid,
  p_status public.waitlist_status,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_entry public.waitlist_entries%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select * into v_entry
    from public.waitlist_entries we
   where we.id = p_entry_id;

  if not found or v_entry.organization_id is distinct from v_org_id then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  -- Lock order: organization advisory lock, then waitlist entry.
  perform authz.assert_org_operational(v_entry.organization_id);

  select * into v_entry
    from public.waitlist_entries we
   where we.id = p_entry_id
   for update;

  if not found then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  perform authz.assert_branch_role(
    v_entry.branch_id,
    array['owner', 'admin', 'manager']::text[]
  );

  if v_entry.status = p_status then
    return jsonb_build_object('entryId', p_entry_id, 'status', p_status);
  end if;

  if not (
    (v_entry.status = 'waiting' and p_status in ('notified', 'cancelled'))
    or (v_entry.status = 'notified' and p_status in ('seated', 'cancelled', 'no_show'))
  ) then
    perform private.raise_app_error(
      'WAITLIST_INVALID_TRANSITION',
      'The requested waitlist status transition is not permitted'
    );
  end if;

  update public.waitlist_entries
     set status = p_status,
         notified_at = case when p_status = 'notified' then now() else notified_at end,
         seated_at = case when p_status = 'seated' then now() else seated_at end,
         cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
         no_show_at = case when p_status = 'no_show' then now() else no_show_at end,
         cancellation_reason = case
           when p_status = 'cancelled' then nullif(btrim(p_reason), '')
           else cancellation_reason
         end
   where id = p_entry_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_entry.branch_id,
    'waitlist.status_updated', 'waitlist_entry', p_entry_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('from_status', v_entry.status, 'to_status', p_status)
  );

  return jsonb_build_object('entryId', p_entry_id, 'status', p_status);
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

  delete from private.rate_limit_buckets rb
   using private.rate_limit_policies rlp
   where rb.policy_key = rlp.policy_key
     and rb.window_start
       + make_interval(secs => rlp.window_seconds)
       < clock_timestamp() - make_interval(secs => p_retention_seconds);

  get diagnostics v_deleted = row_count;
  return v_deleted;
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
  perform authz.acquire_org_shared_lock(v_org_id);

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

  perform authz.acquire_org_exclusive_lock(p_organization_id);

  select o.status into v_previous_status
    from public.organizations o
   where o.id = p_organization_id;

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

  perform authz.acquire_org_exclusive_lock(p_organization_id);

  select o.status into v_previous_status
    from public.organizations o
   where o.id = p_organization_id;

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


create or replace function public.join_waitlist(
  p_branch_id uuid,
  p_party_size integer,
  p_contact_name text default null,
  p_contact_phone text default null,
  p_location_lat numeric default null,
  p_location_lng numeric default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer_id uuid;
  v_branch_org_id uuid;
  v_geolocation_enabled boolean;
  v_radius_meters integer;
  v_branch_lat numeric;
  v_branch_lng numeric;
  v_distance_meters double precision;
  v_location_passed boolean;
  v_entry_id uuid;
  v_joined_at timestamptz;
  v_idem jsonb;
  v_response jsonb;
  v_fingerprint text;
  v_rate_limit jsonb;
begin
  if auth.uid() is null then
    perform private.raise_app_error('AUTH_REQUIRED', 'Authentication is required');
  end if;

  v_customer_id := authz.current_customer_id();

  if v_customer_id is null then
    perform private.raise_app_error('AUTH_ACCOUNT_INACTIVE', 'A customer profile is required');
  end if;

  select b.organization_id,
         b.waitlist_geolocation_enabled,
         b.waitlist_radius_meters,
         b.latitude,
         b.longitude
    into v_branch_org_id,
         v_geolocation_enabled,
         v_radius_meters,
         v_branch_lat,
         v_branch_lng
    from public.branches b
   where b.id = p_branch_id
     and b.status = 'active';

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_org_operational(v_branch_org_id);

  if p_party_size is null or p_party_size <= 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Party size must be positive');
  end if;

  if v_geolocation_enabled then
    if p_location_lat is null
       or p_location_lng is null
       or v_branch_lat is null
       or v_branch_lng is null
       or v_radius_meters is null
    then
      perform private.raise_app_error(
        'WAITLIST_LOCATION_REQUIRED',
        'Location is required to join this waitlist'
      );
    end if;

    v_distance_meters := 6371000 * 2 * asin(
      sqrt(
        power(sin(radians((p_location_lat - v_branch_lat)::double precision) / 2), 2)
        + cos(radians(v_branch_lat::double precision))
          * cos(radians(p_location_lat::double precision))
          * power(sin(radians((p_location_lng - v_branch_lng)::double precision) / 2), 2)
      )
    );

    v_location_passed := v_distance_meters <= v_radius_meters;

    if not v_location_passed then
      perform private.raise_app_error(
        'WAITLIST_DISTANCE_EXCEEDED',
        'The provided location is outside the allowed waitlist radius'
      );
    end if;
  end if;

  v_fingerprint := private.sha256_hex(
    jsonb_build_array(
      p_branch_id,
      p_party_size,
      nullif(btrim(p_contact_name), ''),
      nullif(btrim(p_contact_phone), ''),
      p_location_lat,
      p_location_lng
    )::text
  );

  if p_idempotency_key is not null then
    v_idem := private.idempotency_begin(
      'customer',
      v_customer_id,
      'join_waitlist',
      p_idempotency_key,
      'customer',
      v_customer_id,
      v_fingerprint,
      now() + interval '7 days'
    );

    if v_idem ->> 'status' = 'replay' then
      return v_idem -> 'response';
    end if;
  end if;

  v_rate_limit := private.consume_rate_limit(
    'waitlist_join_customer',
    private.sha256_hex('customer:' || v_customer_id::text)
  );

  if (v_rate_limit ->> 'allowed')::boolean is not true then
    perform private.raise_app_error(
      'RATE_LIMIT_EXCEEDED',
      'Too many waitlist join attempts',
      v_rate_limit
    );
  end if;

  begin
    insert into public.waitlist_entries (
      organization_id,
      branch_id,
      customer_id,
      contact_name,
      contact_phone,
      party_size,
      status,
      location_check_passed,
      location_checked_at
    )
    values (
      v_branch_org_id,
      p_branch_id,
      v_customer_id,
      nullif(btrim(p_contact_name), ''),
      nullif(btrim(p_contact_phone), ''),
      p_party_size,
      'waiting',
      v_location_passed,
      case when v_geolocation_enabled then now() else null end
    )
    returning id, joined_at into v_entry_id, v_joined_at;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'WAITLIST_ENTRY_ALREADY_EXISTS',
        'An active waitlist entry already exists for this customer and branch'
      );
  end;

  perform private.audit_write(
    'customer',
    v_customer_id,
    null,
    v_branch_org_id,
    p_branch_id,
    'waitlist.joined',
    'waitlist_entry',
    v_entry_id,
    null,
    jsonb_build_object('party_size', p_party_size)
  );

  v_response := jsonb_build_object(
    'entryId', v_entry_id,
    'branchId', p_branch_id,
    'status', 'waiting',
    'joinedAt', v_joined_at
  );

  if p_idempotency_key is not null then
    perform private.idempotency_complete((v_idem ->> 'id')::uuid, v_response);
  end if;

  return v_response;
end;
$$;


create or replace function public.add_walk_in(
  p_branch_id uuid,
  p_party_size integer,
  p_contact_name text,
  p_contact_phone text
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
  v_entry_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id
     and b.status = 'active';

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch belongs to another organization');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_operational(v_org_id);

  if p_party_size is null or p_party_size <= 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Party size must be positive');
  end if;

  if nullif(btrim(p_contact_phone), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Contact phone is required for walk-ins');
  end if;

  insert into public.waitlist_entries (
    organization_id,
    branch_id,
    contact_name,
    contact_phone,
    party_size,
    status
  )
  values (
    v_org_id,
    p_branch_id,
    nullif(btrim(p_contact_name), ''),
    btrim(p_contact_phone),
    p_party_size,
    'waiting'
  )
  returning id into v_entry_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_org_id,
    p_branch_id,
    'waitlist.walk_in_created',
    'waitlist_entry',
    v_entry_id,
    null,
    jsonb_build_object('party_size', p_party_size)
  );

  return jsonb_build_object(
    'entryId', v_entry_id,
    'branchId', p_branch_id,
    'status', 'waiting'
  );
end;
$$;

