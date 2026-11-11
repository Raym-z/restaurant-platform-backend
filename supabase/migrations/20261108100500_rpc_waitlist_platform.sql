-- Waitlist and platform-admin RPCs.
--
-- Waitlist queue ordering uses joined_at FIFO because the manual reorder
-- algorithm and no-show thresholds remain unapproved. Notification delivery is
-- not implemented here.

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

  v_fingerprint := md5(
    concat_ws(
      '|',
      p_branch_id::text,
      p_party_size::text,
      coalesce(p_contact_name, ''),
      coalesce(p_contact_phone, ''),
      coalesce(p_location_lat::text, ''),
      coalesce(p_location_lng::text, '')
    )
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
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Branch belongs to another organization');
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

  if not found then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  if v_entry.organization_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Waitlist entry belongs to another organization');
  end if;

  perform authz.assert_branch_role(v_entry.branch_id, array['owner', 'admin', 'manager']::text[]);

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
   where we.id = p_entry_id;

  if not found then
    perform private.raise_app_error('WAITLIST_ENTRY_NOT_FOUND', 'Waitlist entry was not found');
  end if;

  v_customer_id := authz.current_customer_id();

  if v_customer_id is not null and v_entry.customer_id = v_customer_id then
    v_actor_type := 'customer';
    v_actor_id := v_customer_id;
  else
    v_actor_staff_id := authz.require_staff_id();

    if v_entry.organization_id is distinct from authz.current_organization_id() then
      perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Waitlist entry belongs to another organization');
    end if;

    perform authz.assert_branch_role(
      v_entry.branch_id,
      array['owner', 'admin', 'manager']::text[]
    );

    v_actor_type := 'staff';
    v_actor_id := v_actor_staff_id;
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

  if v_customer_id is null or v_entry.customer_id is distinct from v_customer_id then
    perform authz.require_staff_id();

    if v_entry.organization_id is distinct from authz.current_organization_id() then
      perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Waitlist entry belongs to another organization');
    end if;

    perform authz.assert_branch_role(
      v_entry.branch_id,
      array['owner', 'admin', 'manager']::text[]
    );
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

create or replace function public.list_organizations(
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_platform_admin_id uuid;
  v_offset integer;
  v_has_more boolean;
  v_organizations jsonb;
begin
  select pa.id into v_platform_admin_id
    from public.platform_admins pa
   where pa.auth_user_id = auth.uid()
     and pa.revoked_at is null;

  if v_platform_admin_id is null then
    perform private.raise_app_error('PLATFORM_ACCESS_DENIED', 'Platform administrator access is required');
  end if;

  if p_page < 1 or p_page_size < 1 or p_page_size > 100 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Invalid pagination parameters');
  end if;

  v_offset := (p_page - 1) * p_page_size;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'organizationId', o.id,
        'name', o.name,
        'status', o.status,
        'createdAt', o.created_at,
        'branchCount', (
          select count(*)
          from public.branches b
          where b.organization_id = o.id
            and b.status = 'active'
        )
      )
      order by o.created_at desc, o.id
    ),
    '[]'::jsonb
  )
    into v_organizations
    from (
      select o.id, o.name, o.status, o.created_at
      from public.organizations o
      order by o.created_at desc, o.id
      limit p_page_size + 1
      offset v_offset
    ) o;

  v_has_more := jsonb_array_length(v_organizations) > p_page_size;

  if v_has_more then
    select coalesce(
      jsonb_agg(value order by ordinality),
      '[]'::jsonb
    )
      into v_organizations
      from jsonb_array_elements(v_organizations) with ordinality
     where ordinality <= p_page_size;
  end if;

  return jsonb_build_object(
    'organizations', v_organizations,
    'page', p_page,
    'pageSize', p_page_size,
    'hasMore', v_has_more
  );
end;
$$;

create or replace function public.get_organization_metadata(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_platform_admin_id uuid;
  v_result jsonb;
begin
  select pa.id into v_platform_admin_id
    from public.platform_admins pa
   where pa.auth_user_id = auth.uid()
     and pa.revoked_at is null;

  if v_platform_admin_id is null then
    perform private.raise_app_error('PLATFORM_ACCESS_DENIED', 'Platform administrator access is required');
  end if;

  select jsonb_build_object(
    'organizationId', o.id,
    'name', o.name,
    'status', o.status,
    'defaultCurrencyCode', o.default_currency_code,
    'createdAt', o.created_at,
    'deletionRequestedAt', o.deletion_requested_at,
    'deletionScheduledFor', o.deletion_scheduled_for,
    'branches', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'branchId', b.id,
            'name', b.name,
            'timezone', b.timezone,
            'status', b.status
          )
          order by b.created_at
        )
        from public.branches b
        where b.organization_id = o.id
      ),
      '[]'::jsonb
    )
  )
    into v_result
    from public.organizations o
   where o.id = p_organization_id;

  if v_result is null then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  return v_result;
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
   where o.id = p_organization_id;

  if v_previous_status is null then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  update public.organizations
     set status = 'suspended'
   where id = p_organization_id;

  perform private.audit_write(
    'platform_admin',
    v_platform_admin_id,
    null,
    p_organization_id,
    null,
    'platform.organization_suspended',
    'organization',
    p_organization_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('previous_status', v_previous_status)
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
   where o.id = p_organization_id;

  if v_previous_status is null then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  update public.organizations
     set status = 'active'
   where id = p_organization_id;

  perform private.audit_write(
    'platform_admin',
    v_platform_admin_id,
    null,
    p_organization_id,
    null,
    'platform.organization_reactivated',
    'organization',
    p_organization_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('previous_status', v_previous_status)
  );

  return jsonb_build_object('organizationId', p_organization_id, 'status', 'active');
end;
$$;

revoke all on function public.join_waitlist(uuid, integer, text, text, numeric, numeric, text) from public;
revoke all on function public.add_walk_in(uuid, integer, text, text) from public;
revoke all on function public.update_waitlist_status(uuid, public.waitlist_status, text) from public;
revoke all on function public.cancel_waitlist_entry(uuid, text) from public;
revoke all on function public.calculate_waitlist_position(uuid) from public;
revoke all on function public.list_organizations(integer, integer) from public;
revoke all on function public.get_organization_metadata(uuid) from public;
revoke all on function public.suspend_organization(uuid, text) from public;
revoke all on function public.reactivate_organization(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.join_waitlist(uuid, integer, text, text, numeric, numeric, text) to authenticated';
    execute 'grant execute on function public.add_walk_in(uuid, integer, text, text) to authenticated';
    execute 'grant execute on function public.update_waitlist_status(uuid, public.waitlist_status, text) to authenticated';
    execute 'grant execute on function public.cancel_waitlist_entry(uuid, text) to authenticated';
    execute 'grant execute on function public.calculate_waitlist_position(uuid) to authenticated';
    execute 'grant execute on function public.list_organizations(integer, integer) to authenticated';
    execute 'grant execute on function public.get_organization_metadata(uuid) to authenticated';
    execute 'grant execute on function public.suspend_organization(uuid, text) to authenticated';
    execute 'grant execute on function public.reactivate_organization(uuid, text) to authenticated';
  end if;
end
$$;

