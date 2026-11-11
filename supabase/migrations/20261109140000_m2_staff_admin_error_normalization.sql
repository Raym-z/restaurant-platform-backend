-- M2.1 follow-up: normalize staff-administration cross-tenant errors.
--
-- The original definitions live in
-- 20261108110500_security_remediation_error_consistency_menu_staff.sql. Those
-- migrations may already be applied, so this follow-up redefines the three
-- affected RPCs rather than editing an applied migration. It preserves the
-- same authorization checks, audit events, return shapes, and self-service
-- behavior; only the externally observable missing/cross-tenant detail for a
-- staff profile changes.
--
-- Missing and foreign-tenant staff IDs now return the same
-- RESOURCE_CONFLICT detail: 'Staff member was not found'.

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

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
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

revoke all on function public.deactivate_staff(uuid, text) from public;

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

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
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

revoke all on function public.reactivate_staff(uuid) from public;

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

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
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

revoke all on function public.update_staff_profile(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.deactivate_staff(uuid, text) to authenticated';
    execute 'grant execute on function public.reactivate_staff(uuid) to authenticated';
    execute 'grant execute on function public.update_staff_profile(uuid, text) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.deactivate_staff(uuid, text) to service_role';
    execute 'grant execute on function public.reactivate_staff(uuid) to service_role';
    execute 'grant execute on function public.update_staff_profile(uuid, text) to service_role';
  end if;
end
$$;

comment on function public.deactivate_staff(uuid, text) is
  'Deactivates an active staff member in the actor organization. Missing and cross-tenant staff IDs share the Staff member was not found detail.';

comment on function public.reactivate_staff(uuid) is
  'Reactivates a staff member in the actor organization. Missing and cross-tenant staff IDs share the Staff member was not found detail.';

comment on function public.update_staff_profile(uuid, text) is
  'Updates a staff display name. Missing and cross-tenant staff IDs share the Staff member was not found detail.';
