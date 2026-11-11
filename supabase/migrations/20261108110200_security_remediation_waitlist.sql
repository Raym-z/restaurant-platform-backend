-- Security remediation: waitlist concurrency, waitlist rate limiting, and
-- session-wide guest-token revocation.

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
    v_customer_id::text
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
   where we.id = p_entry_id
   for update;

  if not found or v_entry.organization_id is distinct from v_org_id then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  perform authz.assert_org_operational(v_entry.organization_id);
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
    'staff',
    v_actor_staff_id,
    null,
    v_org_id,
    v_entry.branch_id,
    'waitlist.status_updated',
    'waitlist_entry',
    p_entry_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('from_status', v_entry.status, 'to_status', p_status)
  );

  return jsonb_build_object('entryId', p_entry_id, 'status', p_status);
end;
$$;

create or replace function public.cancel_waitlist_entry(
  p_entry_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.waitlist_entries%rowtype;
  v_customer_id uuid;
  v_actor_staff_id uuid;
  v_actor_type public.audit_actor_type;
  v_actor_id uuid;
begin
  select * into v_entry
    from public.waitlist_entries we
   where we.id = p_entry_id
   for update;

  if not found then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  v_customer_id := authz.current_customer_id();

  if v_customer_id is not null and v_entry.customer_id = v_customer_id then
    v_actor_type := 'customer';
    v_actor_id := v_customer_id;
  elsif authz.current_staff_id() is not null then
    v_actor_staff_id := authz.require_staff_id();

    if v_entry.organization_id is distinct from authz.current_organization_id() then
      perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
    end if;

    perform authz.assert_branch_role(
      v_entry.branch_id,
      array['owner', 'admin', 'manager']::text[]
    );

    v_actor_type := 'staff';
    v_actor_id := v_actor_staff_id;
  else
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  if v_entry.status not in ('waiting', 'notified') then
    perform private.raise_app_error(
      'WAITLIST_INVALID_STATUS',
      'Only waiting or notified entries can be cancelled'
    );
  end if;

  update public.waitlist_entries
     set status = 'cancelled',
         cancelled_at = now(),
         cancellation_reason = nullif(btrim(p_reason), '')
   where id = p_entry_id;

  perform private.audit_write(
    v_actor_type,
    v_actor_id,
    null,
    v_entry.organization_id,
    v_entry.branch_id,
    'waitlist.cancelled',
    'waitlist_entry',
    p_entry_id,
    nullif(btrim(p_reason), ''),
    '{}'::jsonb
  );

  return jsonb_build_object('entryId', p_entry_id, 'status', 'cancelled');
end;
$$;

create or replace function public.calculate_waitlist_position(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.waitlist_entries%rowtype;
  v_customer_id uuid;
  v_position integer;
begin
  select * into v_entry
    from public.waitlist_entries we
   where we.id = p_entry_id;

  if not found then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  v_customer_id := authz.current_customer_id();

  if v_customer_id is not null and v_entry.customer_id = v_customer_id then
    null;
  elsif authz.current_staff_id() is not null then
    if v_entry.organization_id is distinct from authz.current_organization_id() then
      perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
    end if;

    perform authz.assert_branch_role(
      v_entry.branch_id,
      array['owner', 'admin', 'manager']::text[]
    );
  else
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  if v_entry.status not in ('waiting', 'notified') then
    perform private.raise_app_error(
      'WAITLIST_INVALID_STATUS',
      'Position is only available for active waitlist entries'
    );
  end if;

  select count(*) + 1
    into v_position
    from public.waitlist_entries other
   where other.branch_id = v_entry.branch_id
     and other.status in ('waiting', 'notified')
     and (
       other.joined_at < v_entry.joined_at
       or (other.joined_at = v_entry.joined_at and other.id < v_entry.id)
     );

  return jsonb_build_object(
    'entryId', p_entry_id,
    'position', v_position,
    'status', v_entry.status
  );
end;
$$;

create or replace function public.revoke_guest_token(
  p_token_id uuid,
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
  v_token_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select gt.organization_id, gt.branch_id
    into v_token_org_id, v_branch_id
    from private.guest_tokens gt
   where gt.id = p_token_id;

  if v_token_org_id is null or v_token_org_id is distinct from v_org_id then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);

  update private.guest_tokens
     set revoked_at = now()
   where id = p_token_id
     and revoked_at is null;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'guest_token.revoked', 'guest_token', p_token_id,
    nullif(btrim(p_reason), ''), '{}'::jsonb
  );

  return jsonb_build_object('tokenId', p_token_id, 'status', 'revoked');
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

  update private.guest_tokens
     set revoked_at = now()
   where dining_session_id = p_session_id
     and revoked_at is null;

  get diagnostics v_revoked_count = row_count;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_org_id,
    v_branch_id,
    'guest_token.session_revoked',
    'dining_session',
    p_session_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('revoked_count', v_revoked_count)
  );

  return jsonb_build_object(
    'sessionId', p_session_id,
    'revokedCount', v_revoked_count
  );
end;
$$;

revoke all on function public.revoke_session_guest_tokens(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.revoke_session_guest_tokens(uuid, text) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.revoke_session_guest_tokens(uuid, text) to service_role';
  end if;
end
$$;
