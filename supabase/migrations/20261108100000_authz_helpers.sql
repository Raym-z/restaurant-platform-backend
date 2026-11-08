-- Backend-services authorization helpers and last-Owner guard.
--
-- RLS policies need callable helper functions. The `private` schema is not
-- usable from policies because client roles have no schema usage. `authz` is a
-- non-exposed helper schema: it is not part of the Data API schemas, but
-- authenticated clients may execute the read-only helpers referenced by RLS.
--
-- Business RPCs remain in `public` and are granted explicitly. Internal trigger
-- functions and service-only helpers remain in `private`.

create schema if not exists authz;

comment on schema authz is
  'Internal RLS authorization helpers. Not exposed through the Data API. Only explicitly granted read-only helpers are executable by authenticated.';

revoke all on schema authz from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant usage on schema authz to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema authz to service_role';
  end if;
end
$$;

create or replace function private.raise_app_error(
  p_code text,
  p_message text default null,
  p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_code,
    detail = coalesce(p_message, ''),
    hint = coalesce(p_details, '{}'::jsonb)::text;
end;
$$;

revoke all on function private.raise_app_error(text, text, jsonb) from public;

create or replace function private.audit_write(
  p_actor_type public.audit_actor_type,
  p_actor_id uuid,
  p_actor_label text,
  p_organization_id uuid,
  p_branch_id uuid,
  p_action text,
  p_target_type text,
  p_target_id uuid,
  p_reason text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_events (
    actor_type,
    actor_id,
    actor_label,
    organization_id,
    branch_id,
    action,
    target_type,
    target_id,
    reason,
    metadata
  )
  values (
    p_actor_type,
    p_actor_id,
    p_actor_label,
    p_organization_id,
    p_branch_id,
    p_action,
    p_target_type,
    p_target_id,
    p_reason,
    coalesce(p_metadata, '{}'::jsonb)
  );
end;
$$;

revoke all on function private.audit_write(
  public.audit_actor_type,
  uuid,
  text,
  uuid,
  uuid,
  text,
  text,
  uuid,
  text,
  jsonb
) from public;

create or replace function authz.current_staff_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select sp.id
  from public.staff_profiles sp
  where sp.auth_user_id = auth.uid()
    and sp.status = 'active'
  limit 1;
$$;

create or replace function authz.current_organization_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select sp.organization_id
  from public.staff_profiles sp
  where sp.auth_user_id = auth.uid()
    and sp.status = 'active'
  limit 1;
$$;

create or replace function authz.current_customer_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cp.id
  from public.customer_profiles cp
  where cp.auth_user_id = auth.uid()
    and cp.deleted_at is null
  limit 1;
$$;

create or replace function authz.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_admins pa
    where pa.auth_user_id = auth.uid()
      and pa.revoked_at is null
  );
$$;

create or replace function authz.has_org_role(p_role_codes text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_profiles sp
    join public.staff_role_assignments sra
      on sra.staff_id = sp.id
     and sra.organization_id = sp.organization_id
    where sp.auth_user_id = auth.uid()
      and sp.status = 'active'
      and sra.revoked_at is null
      and sra.scope_type = 'organization'
      and sra.role_code = any (p_role_codes)
  );
$$;

create or replace function authz.is_org_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select authz.has_org_role(array['owner', 'admin']::text[]);
$$;

create or replace function authz.has_branch_access(p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.branches b
    join public.staff_profiles sp
      on sp.organization_id = b.organization_id
    where b.id = p_branch_id
      and b.status = 'active'
      and sp.auth_user_id = auth.uid()
      and sp.status = 'active'
      and (
        exists (
          select 1
          from public.staff_role_assignments sra
          where sra.staff_id = sp.id
            and sra.revoked_at is null
            and sra.scope_type = 'organization'
        )
        or (
          exists (
            select 1
            from public.staff_role_assignments sra
            where sra.staff_id = sp.id
              and sra.revoked_at is null
              and sra.scope_type = 'branch'
          )
          and exists (
            select 1
            from public.staff_branch_assignments sba
            where sba.staff_id = sp.id
              and sba.branch_id = b.id
              and sba.revoked_at is null
          )
        )
      )
  );
$$;

create or replace function authz.has_branch_role(
  p_branch_id uuid,
  p_role_codes text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.branches b
    join public.staff_profiles sp
      on sp.organization_id = b.organization_id
    join public.staff_role_assignments sra
      on sra.staff_id = sp.id
     and sra.organization_id = sp.organization_id
    where b.id = p_branch_id
      and b.status = 'active'
      and sp.auth_user_id = auth.uid()
      and sp.status = 'active'
      and sra.revoked_at is null
      and sra.role_code = any (p_role_codes)
      and (
        sra.scope_type = 'organization'
        or exists (
          select 1
          from public.staff_branch_assignments sba
          where sba.staff_id = sp.id
            and sba.branch_id = b.id
            and sba.revoked_at is null
        )
      )
  );
$$;

create or replace function authz.can_view_staff(p_staff_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_staff_id = authz.current_staff_id()
    or (
      authz.is_org_admin()
      and exists (
        select 1
        from public.staff_profiles target
        where target.id = p_staff_id
          and target.organization_id = authz.current_organization_id()
      )
    );
$$;

create or replace function authz.has_permission(
  p_permission_code text,
  p_branch_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_profiles sp
    join public.staff_role_assignments sra
      on sra.staff_id = sp.id
     and sra.organization_id = sp.organization_id
    join public.role_permissions rp
      on rp.role_code = sra.role_code
    where sp.auth_user_id = auth.uid()
      and sp.status = 'active'
      and sra.revoked_at is null
      and rp.permission_code = p_permission_code
      and (
        sra.scope_type = 'organization'
        or (
          p_branch_id is not null
          and authz.has_branch_access(p_branch_id)
          and exists (
            select 1
            from public.staff_branch_assignments sba
            where sba.staff_id = sp.id
              and sba.branch_id = p_branch_id
              and sba.revoked_at is null
          )
        )
      )
  );
$$;

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
    'active'::public.subscription_state
  );
$$;

create or replace function authz.org_is_restricted(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select authz.org_subscription_state(p_organization_id) = 'restricted';
$$;

create or replace function authz.has_exceptional_access(
  p_organization_id uuid,
  p_scope text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_admins pa
    join public.exceptional_access_grants eag
      on eag.platform_admin_id = pa.id
    where pa.auth_user_id = auth.uid()
      and pa.revoked_at is null
      and eag.organization_id = p_organization_id
      and eag.scope = p_scope
      and eag.revoked_at is null
      and eag.starts_at <= now()
      and eag.expires_at > now()
  );
$$;

create or replace function authz.require_staff_id()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff_id uuid;
begin
  if auth.uid() is null then
    perform private.raise_app_error('AUTH_REQUIRED', 'Authentication is required');
  end if;

  v_staff_id := authz.current_staff_id();

  if v_staff_id is null then
    perform private.raise_app_error('STAFF_NOT_ACTIVE', 'No active staff membership was found');
  end if;

  return v_staff_id;
end;
$$;

create or replace function authz.require_organization_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select authz.current_organization_id();
$$;

create or replace function authz.assert_org_role(p_role_codes text[])
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not authz.has_org_role(p_role_codes) then
    perform private.raise_app_error('PERMISSION_DENIED', 'Organization role is not permitted');
  end if;
end;
$$;

create or replace function authz.assert_branch_access(p_branch_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not authz.has_branch_access(p_branch_id) then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Branch access is not permitted');
  end if;
end;
$$;

create or replace function authz.assert_branch_role(
  p_branch_id uuid,
  p_role_codes text[]
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not authz.has_branch_role(p_branch_id, p_role_codes) then
    perform private.raise_app_error('PERMISSION_DENIED', 'Branch role is not permitted');
  end if;
end;
$$;

create or replace function authz.assert_org_operational(p_organization_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
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
stable
security definer
set search_path = ''
as $$
begin
  perform authz.assert_org_operational(p_organization_id);
end;
$$;

revoke all on function private.raise_app_error(text, text, jsonb) from public;
revoke all on function authz.current_staff_id() from public;
revoke all on function authz.current_organization_id() from public;
revoke all on function authz.current_customer_id() from public;
revoke all on function authz.is_platform_admin() from public;
revoke all on function authz.has_org_role(text[]) from public;
revoke all on function authz.is_org_admin() from public;
revoke all on function authz.has_branch_access(uuid) from public;
revoke all on function authz.has_branch_role(uuid, text[]) from public;
revoke all on function authz.can_view_staff(uuid) from public;
revoke all on function authz.has_permission(text, uuid) from public;
revoke all on function authz.org_subscription_state(uuid) from public;
revoke all on function authz.org_is_restricted(uuid) from public;
revoke all on function authz.has_exceptional_access(uuid, text) from public;
revoke all on function authz.require_staff_id() from public;
revoke all on function authz.require_organization_id() from public;
revoke all on function authz.assert_org_role(text[]) from public;
revoke all on function authz.assert_branch_access(uuid) from public;
revoke all on function authz.assert_branch_role(uuid, text[]) from public;
revoke all on function authz.assert_org_operational(uuid) from public;
revoke all on function authz.assert_org_can_administer(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function authz.current_staff_id() to authenticated';
    execute 'grant execute on function authz.current_organization_id() to authenticated';
    execute 'grant execute on function authz.current_customer_id() to authenticated';
    execute 'grant execute on function authz.is_platform_admin() to authenticated';
    execute 'grant execute on function authz.has_org_role(text[]) to authenticated';
    execute 'grant execute on function authz.is_org_admin() to authenticated';
    execute 'grant execute on function authz.has_branch_access(uuid) to authenticated';
    execute 'grant execute on function authz.has_branch_role(uuid, text[]) to authenticated';
    execute 'grant execute on function authz.can_view_staff(uuid) to authenticated';
    execute 'grant execute on function authz.has_permission(text, uuid) to authenticated';
    execute 'grant execute on function authz.org_subscription_state(uuid) to authenticated';
    execute 'grant execute on function authz.org_is_restricted(uuid) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function authz.current_staff_id() to service_role';
    execute 'grant execute on function authz.current_organization_id() to service_role';
    execute 'grant execute on function authz.current_customer_id() to service_role';
    execute 'grant execute on function authz.is_platform_admin() to service_role';
    execute 'grant execute on function authz.has_org_role(text[]) to service_role';
    execute 'grant execute on function authz.is_org_admin() to service_role';
    execute 'grant execute on function authz.has_branch_access(uuid) to service_role';
    execute 'grant execute on function authz.has_branch_role(uuid, text[]) to service_role';
    execute 'grant execute on function authz.can_view_staff(uuid) to service_role';
    execute 'grant execute on function authz.has_permission(text, uuid) to service_role';
    execute 'grant execute on function authz.org_subscription_state(uuid) to service_role';
    execute 'grant execute on function authz.org_is_restricted(uuid) to service_role';
  end if;
end
$$;

-- Last-Owner protection. The schema enforces at most one active Owner; these
-- guards prevent removing the only active Owner through role revocation or
-- staff deactivation.
create or replace function private.guard_last_owner_role_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_removing_owner boolean;
begin
  v_org_id := old.organization_id;

  if tg_op = 'DELETE' then
    v_removing_owner := old.role_code = 'owner' and old.revoked_at is null;
  else
    v_removing_owner :=
      old.role_code = 'owner'
      and old.revoked_at is null
      and (
        new.revoked_at is not null
        or new.role_code <> 'owner'
      );
  end if;

  if v_removing_owner then
    if not exists (
      select 1
      from public.staff_role_assignments sra
      where sra.organization_id = v_org_id
        and sra.role_code = 'owner'
        and sra.revoked_at is null
        and sra.id <> old.id
    ) then
      perform private.raise_app_error(
        'LAST_OWNER_PROTECTED',
        'The last active Owner cannot be removed'
      );
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create or replace function private.guard_last_owner_staff_deactivation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'active'
     and new.status in ('suspended', 'deactivated')
     and exists (
       select 1
       from public.staff_role_assignments sra
       where sra.staff_id = old.id
         and sra.role_code = 'owner'
         and sra.revoked_at is null
     )
     and not exists (
       select 1
       from public.staff_role_assignments sra
       join public.staff_profiles sp on sp.id = sra.staff_id
       where sra.organization_id = old.organization_id
         and sra.role_code = 'owner'
         and sra.revoked_at is null
         and sp.status = 'active'
         and sp.id <> old.id
     )
  then
    perform private.raise_app_error(
      'LAST_OWNER_PROTECTED',
      'The last active Owner cannot be deactivated'
    );
  end if;

  return new;
end;
$$;

revoke all on function private.guard_last_owner_role_change() from public;
revoke all on function private.guard_last_owner_staff_deactivation() from public;

create trigger staff_role_assignments_guard_last_owner
  before update or delete on public.staff_role_assignments
  for each row execute function private.guard_last_owner_role_change();

create trigger staff_profiles_guard_last_owner
  before update of status on public.staff_profiles
  for each row execute function private.guard_last_owner_staff_deactivation();

comment on schema authz is
  'Internal RLS authorization helpers. Not exposed through the Data API. RLS policies call these helpers; authenticated clients only receive execute grants for read-only helpers.';

comment on function authz.has_permission(text, uuid) is
  'Permission checks are fail-closed while public.role_permissions is empty. Do not seed unapproved mappings.';

comment on function private.guard_last_owner_role_change() is
  'Prevents revoking, replacing, or deleting the only active Owner assignment.';
