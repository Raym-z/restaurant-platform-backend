-- Security remediation: normalize remaining organization/branch/table
-- cross-tenant errors to not-found where the operation is otherwise unchanged.

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
    perform private.raise_app_error('ORGANIZATION_NOT_FOUND', 'Organization was not found');
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

  if v_org_id is null or v_org_id is distinct from authz.current_organization_id() then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
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

create or replace function public.update_table(
  p_table_id uuid,
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

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_label), '') is null or p_capacity <= 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Table label and capacity are required');
  end if;

  update public.restaurant_tables
     set label = btrim(p_label),
         capacity = p_capacity
   where id = p_table_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'table.updated', 'restaurant_table', p_table_id, null,
    jsonb_build_object('label', btrim(p_label), 'capacity', p_capacity)
  );

  return jsonb_build_object('tableId', p_table_id, 'label', btrim(p_label), 'capacity', p_capacity);
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
   where rt.id = p_table_id
   for update;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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
