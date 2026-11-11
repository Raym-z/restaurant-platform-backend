-- Security remediation: organization, branch, table, and guest-session RPCs.
--
-- Fixes:
--   * SHA-256 canonical idempotency fingerprints.
--   * Branch-limit serialization with a subscription row lock.
--   * Session creation vs table/branch deactivation and QR rotation races.
--   * Organization operational-status enforcement.
--   * Guest session/token creation audit.
--   * Cross-tenant resource errors normalized to not-found for these RPCs.

create or replace function public.register_organization(
  p_name text,
  p_branch_name text,
  p_branch_timezone text,
  p_owner_display_name text,
  p_branch_address text default null,
  p_branch_phone text default null,
  p_currency_code text default 'IDR',
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_plan_code text;
  v_organization_id uuid;
  v_branch_id uuid;
  v_staff_id uuid;
  v_idem jsonb;
  v_response jsonb;
  v_fingerprint text;
begin
  if v_auth_user_id is null then
    perform private.raise_app_error('AUTH_REQUIRED', 'Authentication is required');
  end if;

  if nullif(btrim(p_name), '') is null
     or nullif(btrim(p_branch_name), '') is null
     or nullif(btrim(p_branch_timezone), '') is null
     or nullif(btrim(p_owner_display_name), '') is null
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'Required organization fields are missing');
  end if;

  if not exists (
    select 1 from public.currencies c where c.code = p_currency_code
  ) then
    perform private.raise_app_error('VALIDATION_ERROR', 'Unsupported currency code');
  end if;

  v_fingerprint := private.sha256_hex(
    jsonb_build_array(
      btrim(p_name),
      btrim(p_branch_name),
      btrim(p_branch_timezone),
      btrim(p_owner_display_name),
      nullif(btrim(p_branch_address), ''),
      nullif(btrim(p_branch_phone), ''),
      upper(p_currency_code)
    )::text
  );

  if p_idempotency_key is not null then
    v_idem := private.idempotency_begin(
      'auth_user',
      v_auth_user_id,
      'register_organization',
      p_idempotency_key,
      'staff',
      null,
      v_fingerprint,
      now() + interval '7 days'
    );

    if v_idem ->> 'status' = 'replay' then
      return v_idem -> 'response';
    end if;
  end if;

  if exists (
    select 1 from public.staff_profiles sp where sp.auth_user_id = v_auth_user_id
  ) then
    perform private.raise_app_error(
      'STAFF_ALREADY_MEMBER',
      'This account already belongs to an organization'
    );
  end if;

  select p.code
    into v_plan_code
    from public.plans p
   where p.is_free
     and p.is_active
   limit 1;

  if v_plan_code is null then
    perform private.raise_app_error(
      'SUBSCRIPTION_PLAN_UNAVAILABLE',
      'No active Free plan is configured'
    );
  end if;

  insert into public.organizations (name, default_currency_code)
  values (btrim(p_name), p_currency_code)
  returning id into v_organization_id;

  insert into public.branches (
    organization_id,
    name,
    timezone,
    address,
    phone
  )
  values (
    v_organization_id,
    btrim(p_branch_name),
    btrim(p_branch_timezone),
    nullif(btrim(p_branch_address), ''),
    nullif(btrim(p_branch_phone), '')
  )
  returning id into v_branch_id;

  insert into public.staff_profiles (
    auth_user_id,
    organization_id,
    display_name,
    status,
    invited_at,
    activated_at
  )
  values (
    v_auth_user_id,
    v_organization_id,
    btrim(p_owner_display_name),
    'active',
    now(),
    now()
  )
  returning id into v_staff_id;

  insert into public.staff_role_assignments (
    staff_id,
    organization_id,
    role_code,
    scope_type,
    assigned_by_staff_id
  )
  values (
    v_staff_id,
    v_organization_id,
    'owner',
    'organization',
    null
  );

  insert into public.subscriptions (organization_id, plan_code, state)
  values (v_organization_id, v_plan_code, 'active');

  perform private.audit_write(
    'staff',
    v_staff_id,
    null,
    v_organization_id,
    v_branch_id,
    'organization.registered',
    'organization',
    v_organization_id,
    null,
    jsonb_build_object('plan_code', v_plan_code)
  );

  v_response := jsonb_build_object(
    'organizationId', v_organization_id,
    'branchId', v_branch_id,
    'staffId', v_staff_id,
    'planCode', v_plan_code
  );

  if p_idempotency_key is not null then
    perform private.idempotency_complete((v_idem ->> 'id')::uuid, v_response);
  end if;

  return v_response;
end;
$$;

create or replace function public.create_branch(
  p_organization_id uuid,
  p_name text,
  p_timezone text,
  p_branch_address text default null,
  p_branch_phone text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_plan_code text;
  v_branch_limit integer;
  v_branch_count integer;
  v_branch_id uuid;
  v_idem jsonb;
  v_response jsonb;
  v_fingerprint text;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  if p_organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if nullif(btrim(p_name), '') is null
     or nullif(btrim(p_timezone), '') is null
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'Branch name and timezone are required');
  end if;

  v_fingerprint := private.sha256_hex(
    jsonb_build_array(
      p_organization_id,
      btrim(p_name),
      btrim(p_timezone),
      nullif(btrim(p_branch_address), ''),
      nullif(btrim(p_branch_phone), '')
    )::text
  );

  if p_idempotency_key is not null then
    v_idem := private.idempotency_begin(
      'staff',
      v_actor_staff_id,
      'create_branch',
      p_idempotency_key,
      'staff',
      v_actor_staff_id,
      v_fingerprint,
      now() + interval '7 days'
    );

    if v_idem ->> 'status' = 'replay' then
      return v_idem -> 'response';
    end if;
  end if;

  -- Serialize branch creation per organization so concurrent requests cannot
  -- both observe a count below the plan limit.
  perform 1
    from public.subscriptions s
   where s.organization_id = v_actor_org_id
   for update;

  select s.plan_code, p.branch_limit
    into v_plan_code, v_branch_limit
    from public.subscriptions s
    join public.plans p on p.code = s.plan_code
   where s.organization_id = v_actor_org_id;

  if v_plan_code is null then
    perform private.raise_app_error(
      'SUBSCRIPTION_PLAN_UNAVAILABLE',
      'No subscription plan is configured for this organization'
    );
  end if;

  select count(*)
    into v_branch_count
    from public.branches b
   where b.organization_id = v_actor_org_id
     and b.status = 'active';

  if v_branch_limit is not null and v_branch_count >= v_branch_limit then
    perform private.raise_app_error(
      'BRANCH_LIMIT_REACHED',
      'The organization has reached its branch limit'
    );
  end if;

  insert into public.branches (
    organization_id,
    name,
    timezone,
    address,
    phone
  )
  values (
    v_actor_org_id,
    btrim(p_name),
    btrim(p_timezone),
    nullif(btrim(p_branch_address), ''),
    nullif(btrim(p_branch_phone), '')
  )
  returning id into v_branch_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    v_branch_id,
    'branch.created',
    'branch',
    v_branch_id,
    null,
    jsonb_build_object('name', btrim(p_name), 'timezone', btrim(p_timezone))
  );

  v_response := jsonb_build_object(
    'branchId', v_branch_id,
    'organizationId', v_actor_org_id,
    'name', btrim(p_name),
    'timezone', btrim(p_timezone)
  );

  if p_idempotency_key is not null then
    perform private.idempotency_complete((v_idem ->> 'id')::uuid, v_response);
  end if;

  return v_response;
end;
$$;

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
   where b.id = p_branch_id
   for update;

  if v_branch_org_id is null or v_branch_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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
   where b.id = p_branch_id
   for update;

  if v_org_id is null or v_org_id is distinct from authz.current_organization_id() then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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
    'staff',
    v_actor_staff_id,
    null,
    v_org_id,
    p_branch_id,
    'branch.deactivated',
    'branch',
    p_branch_id,
    nullif(btrim(p_reason), ''),
    '{}'::jsonb
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
   where rt.id = p_table_id
   for update;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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

  -- Resolve the identifiers first, then lock branch and table before
  -- re-validating mutable state. This serializes against deactivation and QR
  -- regeneration without holding a lock while doing extra work.
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

  if authz.org_is_restricted(v_org_id) then
    perform private.raise_app_error(
      'SUBSCRIPTION_RESTRICTED',
      'New guest sessions and tokens are blocked while the organization subscription is restricted'
    );
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

  begin
    insert into private.guest_tokens (
      organization_id,
      branch_id,
      dining_session_id,
      token_hash,
      expires_at,
      device_label
    )
    values (
      v_org_id,
      v_branch_id,
      v_session_id,
      decode(p_token_hash_hex, 'hex'),
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
      'guest',
      null,
      null,
      v_org_id,
      v_branch_id,
      'dining_session.created',
      'dining_session',
      v_session_id,
      null,
      jsonb_build_object('table_id', v_table_id)
    );
  end if;

  perform private.audit_write(
    'guest',
    null,
    null,
    v_org_id,
    v_branch_id,
    'guest_token.issued',
    'guest_token',
    v_token_id,
    null,
    jsonb_build_object(
      'session_id', v_session_id,
      'expires_at', p_expires_at
    )
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
     and o.status in ('active', 'pending_deletion')
     and o.deleted_at is null
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
