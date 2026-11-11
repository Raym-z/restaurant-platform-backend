-- Organization, branch, and staff RPCs.
--
-- Authorization is based on documented role scope: Owner/Admin administer the
-- organization; Manager/Admin may operate assigned branches. Granular
-- permission mappings remain unapproved and are not seeded.

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

  v_fingerprint := md5(
    concat_ws(
      '|',
      p_name,
      p_branch_name,
      p_branch_timezone,
      p_owner_display_name,
      coalesce(p_branch_address, ''),
      coalesce(p_branch_phone, ''),
      p_currency_code
    )
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

create or replace function public.update_organization(
  p_organization_id uuid,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  if p_organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Organization access is not permitted');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if nullif(btrim(p_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Organization name is required');
  end if;

  update public.organizations
     set name = btrim(p_name)
   where id = p_organization_id;

  if not found then
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
  end if;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'organization.updated',
    'organization',
    p_organization_id,
    null,
    jsonb_build_object('name', btrim(p_name))
  );

  return jsonb_build_object('organizationId', p_organization_id, 'name', btrim(p_name));
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
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Organization access is not permitted');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if nullif(btrim(p_name), '') is null
     or nullif(btrim(p_timezone), '') is null
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'Branch name and timezone are required');
  end if;

  v_fingerprint := md5(
    concat_ws(
      '|',
      p_organization_id::text,
      p_name,
      p_timezone,
      coalesce(p_branch_address, ''),
      coalesce(p_branch_phone, '')
    )
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

create or replace function public.update_branch(
  p_branch_id uuid,
  p_name text,
  p_timezone text,
  p_branch_address text default null,
  p_branch_phone text default null
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

  if v_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_org_id is distinct from authz.current_organization_id() then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Branch access is not permitted');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_name), '') is null
     or nullif(btrim(p_timezone), '') is null
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'Branch name and timezone are required');
  end if;

  update public.branches
     set name = btrim(p_name),
         timezone = btrim(p_timezone),
         address = nullif(btrim(p_branch_address), ''),
         phone = nullif(btrim(p_branch_phone), '')
   where id = p_branch_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_org_id,
    p_branch_id,
    'branch.updated',
    'branch',
    p_branch_id,
    null,
    jsonb_build_object('name', btrim(p_name), 'timezone', btrim(p_timezone))
  );

  return jsonb_build_object(
    'branchId', p_branch_id,
    'organizationId', v_org_id,
    'name', btrim(p_name),
    'timezone', btrim(p_timezone)
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

  if v_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_org_id is distinct from authz.current_organization_id() then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Branch access is not permitted');
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

create or replace function public.grant_staff_role(
  p_staff_id uuid,
  p_role_code text,
  p_scope_type public.role_scope,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
  v_assignment_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('STAFF_NOT_FOUND', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Staff member belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if p_role_code = 'owner' then
    perform private.raise_app_error(
      'PERMISSION_DENIED',
      'Ownership transfer is not available in the initial release'
    );
  end if;

  if p_role_code = 'admin' and not authz.has_org_role(array['owner']::text[]) then
    perform private.raise_app_error(
      'PERMISSION_DENIED',
      'Only the Owner may grant the Admin role'
    );
  end if;

  if p_role_code not in ('admin', 'manager', 'cashier', 'kitchen_staff') then
    perform private.raise_app_error('VALIDATION_ERROR', 'Unsupported role');
  end if;

  if p_role_code in ('manager', 'cashier', 'kitchen_staff')
     and p_scope_type <> 'branch'
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'This role requires branch scope');
  end if;

  begin
    insert into public.staff_role_assignments (
      staff_id,
      organization_id,
      role_code,
      scope_type,
      assigned_by_staff_id,
      reason
    )
    values (
      p_staff_id,
      v_actor_org_id,
      p_role_code,
      p_scope_type,
      v_actor_staff_id,
      nullif(btrim(p_reason), '')
    )
    returning id into v_assignment_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'An equivalent active role assignment already exists'
      );
  end;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.role_granted',
    'staff',
    p_staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('role_code', p_role_code, 'scope_type', p_scope_type)
  );

  return jsonb_build_object(
    'assignmentId', v_assignment_id,
    'staffId', p_staff_id,
    'roleCode', p_role_code,
    'scope', p_scope_type
  );
end;
$$;

create or replace function public.revoke_staff_role(
  p_assignment_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_assignment public.staff_role_assignments%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select * into v_assignment
    from public.staff_role_assignments sra
   where sra.id = p_assignment_id;

  if not found then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment was not found');
  end if;

  if v_assignment.organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Role assignment belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if v_assignment.role_code = 'admin'
     and not authz.has_org_role(array['owner']::text[])
  then
    perform private.raise_app_error('PERMISSION_DENIED', 'Only the Owner may revoke the Admin role');
  end if;

  if v_assignment.revoked_at is not null then
    return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'already_revoked');
  end if;

  update public.staff_role_assignments
     set revoked_at = now(),
         revoked_by_staff_id = v_actor_staff_id,
         reason = nullif(btrim(p_reason), '')
   where id = p_assignment_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.role_revoked',
    'staff',
    v_assignment.staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('role_code', v_assignment.role_code, 'scope_type', v_assignment.scope_type)
  );

  return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'revoked');
end;
$$;

create or replace function public.assign_staff_branch(
  p_staff_id uuid,
  p_branch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
  v_branch_org_id uuid;
  v_assignment_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('STAFF_NOT_FOUND', 'Staff member was not found');
  end if;

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id
     or v_branch_org_id is distinct from v_actor_org_id
  then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Staff or branch belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  begin
    insert into public.staff_branch_assignments (
      staff_id,
      organization_id,
      branch_id,
      assigned_by_staff_id
    )
    values (
      p_staff_id,
      v_actor_org_id,
      p_branch_id,
      v_actor_staff_id
    )
    returning id into v_assignment_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'An equivalent active branch assignment already exists'
      );
  end;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    p_branch_id,
    'staff.branch_assigned',
    'staff',
    p_staff_id,
    null,
    jsonb_build_object('branch_id', p_branch_id)
  );

  return jsonb_build_object(
    'assignmentId', v_assignment_id,
    'staffId', p_staff_id,
    'branchId', p_branch_id
  );
end;
$$;

create or replace function public.revoke_staff_branch(
  p_assignment_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_assignment public.staff_branch_assignments%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select * into v_assignment
    from public.staff_branch_assignments sba
   where sba.id = p_assignment_id;

  if not found then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch assignment was not found');
  end if;

  if v_assignment.organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Branch assignment belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if v_assignment.revoked_at is not null then
    return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'already_revoked');
  end if;

  update public.staff_branch_assignments
     set revoked_at = now()
   where id = p_assignment_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    v_assignment.branch_id,
    'staff.branch_revoked',
    'staff',
    v_assignment.staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('branch_id', v_assignment.branch_id)
  );

  return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'revoked');
end;
$$;

create or replace function public.deactivate_staff(
  p_staff_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  if p_staff_id = v_actor_staff_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'You cannot deactivate your own membership');
  end if;

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('STAFF_NOT_FOUND', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Staff member belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  update public.staff_profiles
     set status = 'deactivated',
         deactivated_at = now()
   where id = p_staff_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.deactivated',
    'staff',
    p_staff_id,
    nullif(btrim(p_reason), ''),
    '{}'::jsonb
  );

  return jsonb_build_object('staffId', p_staff_id, 'status', 'deactivated');
end;
$$;

create or replace function public.reactivate_staff(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('STAFF_NOT_FOUND', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Staff member belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  update public.staff_profiles
     set status = 'active',
         activated_at = now(),
         deactivated_at = null
   where id = p_staff_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.reactivated',
    'staff',
    p_staff_id,
    null,
    '{}'::jsonb
  );

  return jsonb_build_object('staffId', p_staff_id, 'status', 'active');
end;
$$;

create or replace function public.update_staff_profile(
  p_staff_id uuid,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('STAFF_NOT_FOUND', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Staff member belongs to another organization');
  end if;

  if p_staff_id <> v_actor_staff_id then
    perform authz.assert_org_role(array['owner', 'admin']::text[]);
    perform authz.assert_org_can_administer(v_actor_org_id);
  end if;

  if nullif(btrim(p_display_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Display name is required');
  end if;

  update public.staff_profiles
     set display_name = btrim(p_display_name)
   where id = p_staff_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.profile_updated',
    'staff',
    p_staff_id,
    null,
    jsonb_build_object('display_name', btrim(p_display_name))
  );

  return jsonb_build_object('staffId', p_staff_id, 'displayName', btrim(p_display_name));
end;
$$;

revoke all on function public.register_organization(text, text, text, text, text, text, text, text) from public;
revoke all on function public.update_organization(uuid, text) from public;
revoke all on function public.create_branch(uuid, text, text, text, text, text) from public;
revoke all on function public.update_branch(uuid, text, text, text, text) from public;
revoke all on function public.deactivate_branch(uuid, text) from public;
revoke all on function public.grant_staff_role(uuid, text, public.role_scope, text) from public;
revoke all on function public.revoke_staff_role(uuid, text) from public;
revoke all on function public.assign_staff_branch(uuid, uuid) from public;
revoke all on function public.revoke_staff_branch(uuid, text) from public;
revoke all on function public.deactivate_staff(uuid, text) from public;
revoke all on function public.reactivate_staff(uuid) from public;
revoke all on function public.update_staff_profile(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.register_organization(text, text, text, text, text, text, text, text) to authenticated';
    execute 'grant execute on function public.update_organization(uuid, text) to authenticated';
    execute 'grant execute on function public.create_branch(uuid, text, text, text, text, text) to authenticated';
    execute 'grant execute on function public.update_branch(uuid, text, text, text, text) to authenticated';
    execute 'grant execute on function public.deactivate_branch(uuid, text) to authenticated';
    execute 'grant execute on function public.grant_staff_role(uuid, text, public.role_scope, text) to authenticated';
    execute 'grant execute on function public.revoke_staff_role(uuid, text) to authenticated';
    execute 'grant execute on function public.assign_staff_branch(uuid, uuid) to authenticated';
    execute 'grant execute on function public.revoke_staff_branch(uuid, text) to authenticated';
    execute 'grant execute on function public.deactivate_staff(uuid, text) to authenticated';
    execute 'grant execute on function public.reactivate_staff(uuid) to authenticated';
    execute 'grant execute on function public.update_staff_profile(uuid, text) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.register_organization(text, text, text, text, text, text, text, text) to service_role';
    execute 'grant execute on function public.update_organization(uuid, text) to service_role';
    execute 'grant execute on function public.create_branch(uuid, text, text, text, text, text) to service_role';
    execute 'grant execute on function public.update_branch(uuid, text, text, text, text) to service_role';
    execute 'grant execute on function public.deactivate_branch(uuid, text) to service_role';
    execute 'grant execute on function public.grant_staff_role(uuid, text, public.role_scope, text) to service_role';
    execute 'grant execute on function public.revoke_staff_role(uuid, text) to service_role';
    execute 'grant execute on function public.assign_staff_branch(uuid, uuid) to service_role';
    execute 'grant execute on function public.revoke_staff_branch(uuid, text) to service_role';
    execute 'grant execute on function public.deactivate_staff(uuid, text) to service_role';
    execute 'grant execute on function public.reactivate_staff(uuid) to service_role';
    execute 'grant execute on function public.update_staff_profile(uuid, text) to service_role';
  end if;
end
$$;
