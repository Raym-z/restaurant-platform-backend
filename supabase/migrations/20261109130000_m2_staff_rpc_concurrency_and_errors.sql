-- M2.1 concurrency, lock-order, and error-normalization follow-up.
--
-- This migration is intentionally separate from
-- 20261109120000_m2_branch_scoped_staff_roles_fixes.sql so environments that
-- already applied that migration receive the fixes through a new migration.
--
-- Fixes:
--   * F1: serializes concurrent revoke_staff_branch calls and writes one
--     staff.branch_revoked audit event.
--   * F2: resolves the actor, validates the target organization, and acquires
--     the organization advisory lock before locking the role-assignment row.
--     The assignment is re-read after locking.
--   * F5: the legacy backfill takes a SHARE lock on staff_branch_assignments so
--     concurrent branch-assignment changes cannot interleave with the split.
--   * F6: organization-scoped has_permission validates a supplied branch's
--     tenant and active status instead of ignoring it.
--   * F7: missing-resource and cross-tenant staff errors use identical details.

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
  v_assignment_org_id uuid;
  v_assignment public.staff_branch_assignments%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  -- Unlocked existence/tenant read. Missing and foreign assignments share one
  -- response so callers cannot distinguish them.
  select sba.organization_id into v_assignment_org_id
    from public.staff_branch_assignments sba
   where sba.id = p_assignment_id;

  if v_assignment_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch assignment was not found');
  end if;

  -- Lock order: actor identity and organization checks first. The organization
  -- advisory lock is acquired by assert_org_can_administer before the row lock.
  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  select * into v_assignment
    from public.staff_branch_assignments sba
   where sba.id = p_assignment_id
   for update;

  if not found then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch assignment was not found');
  end if;

  if v_assignment.organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch assignment was not found');
  end if;

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

revoke all on function public.revoke_staff_branch(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.revoke_staff_branch(uuid, text) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.revoke_staff_branch(uuid, text) to service_role';
  end if;
end
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
  v_assignment_org_id uuid;
  v_assignment public.staff_role_assignments%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  -- Unlocked existence/tenant read. Missing and foreign assignments share one
  -- response so callers cannot distinguish them.
  select sra.organization_id into v_assignment_org_id
    from public.staff_role_assignments sra
   where sra.id = p_assignment_id;

  if v_assignment_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment was not found');
  end if;

  -- Lock order: actor identity, target organization, and authorization before
  -- the assignment row. assert_org_can_administer acquires the organization
  -- advisory lock before the row lock below.
  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  select * into v_assignment
    from public.staff_role_assignments sra
   where sra.id = p_assignment_id
   for update;

  if not found then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment was not found');
  end if;

  if v_assignment.organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment was not found');
  end if;

  if v_assignment.role_code = 'admin'
     and not authz.has_org_role(array['owner']::text[])
  then
    perform private.raise_app_error('PERMISSION_DENIED', 'Only the Owner may revoke the Admin role');
  end if;

  if v_assignment.revoked_at is not null then
    return jsonb_build_object(
      'assignmentId', p_assignment_id,
      'staffId', v_assignment.staff_id,
      'branchId', v_assignment.branch_id,
      'status', 'already_revoked'
    );
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
    v_assignment.branch_id,
    'staff.role_revoked',
    'staff',
    v_assignment.staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object(
      'role_code', v_assignment.role_code,
      'scope_type', v_assignment.scope_type,
      'branch_id', v_assignment.branch_id
    )
  );

  return jsonb_build_object(
    'assignmentId', p_assignment_id,
    'staffId', v_assignment.staff_id,
    'branchId', v_assignment.branch_id,
    'status', 'revoked'
  );
end;
$$;

revoke all on function public.revoke_staff_role(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.revoke_staff_role(uuid, text) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.revoke_staff_role(uuid, text) to service_role';
  end if;
end
$$;

create or replace function public.grant_staff_role(
  p_staff_id uuid,
  p_role_code text,
  p_scope_type public.role_scope,
  p_reason text default null,
  p_branch_id uuid default null
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

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
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

  if p_role_code is null
     or p_role_code not in ('admin', 'manager', 'cashier', 'kitchen_staff')
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'Unsupported role');
  end if;

  if p_scope_type is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Role scope is required');
  end if;

  if p_scope_type = 'organization' then
    if p_branch_id is not null then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'Organization-scoped assignments must not include a branch'
      );
    end if;
  else
    if p_branch_id is null then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'Branch-scoped assignments require a branch'
      );
    end if;

    select b.organization_id into v_branch_org_id
      from public.branches b
     where b.id = p_branch_id;

    if v_branch_org_id is distinct from v_actor_org_id then
      perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch was not found');
    end if;
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
      branch_id,
      assigned_by_staff_id,
      reason
    )
    values (
      p_staff_id,
      v_actor_org_id,
      p_role_code,
      p_scope_type,
      p_branch_id,
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
    p_branch_id,
    'staff.role_granted',
    'staff',
    p_staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object(
      'role_code', p_role_code,
      'scope_type', p_scope_type,
      'branch_id', p_branch_id
    )
  );

  return jsonb_build_object(
    'assignmentId', v_assignment_id,
    'staffId', p_staff_id,
    'roleCode', p_role_code,
    'scope', p_scope_type,
    'branchId', p_branch_id
  );
end;
$$;

revoke all on function public.grant_staff_role(
  uuid,
  text,
  public.role_scope,
  text,
  uuid
) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.grant_staff_role(uuid, text, public.role_scope, text, uuid) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.grant_staff_role(uuid, text, public.role_scope, text, uuid) to service_role';
  end if;
end
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

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch was not found');
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

revoke all on function public.assign_staff_branch(uuid, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.assign_staff_branch(uuid, uuid) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.assign_staff_branch(uuid, uuid) to service_role';
  end if;
end
$$;

-- F5: lock staff_branch_assignments against concurrent writes for the duration
-- of the backfill transaction. The migration already holds ACCESS EXCLUSIVE on
-- staff_role_assignments; this closes the remaining race on branch assignments.
create or replace function private.backfill_legacy_branch_role_assignments()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assignment public.staff_role_assignments%rowtype;
  v_branches uuid[];
  v_branch_id uuid;
  v_index integer;
begin
  lock table public.staff_branch_assignments in share mode;

  for v_assignment in
    select sra.*
    from public.staff_role_assignments sra
    where sra.scope_type = 'branch'
      and sra.branch_id is null
    order by sra.id
  loop
    select array_agg(candidate.branch_id order by candidate.branch_id)
      into v_branches
      from (
        select distinct sba.branch_id
        from public.staff_branch_assignments sba
        where sba.staff_id = v_assignment.staff_id
          and sba.organization_id = v_assignment.organization_id
          and (
            v_assignment.revoked_at is not null
            or sba.revoked_at is null
          )
      ) candidate;

    if v_branches is null or cardinality(v_branches) = 0 then
      raise exception using
        errcode = 'P0001',
        message = 'LEGACY_BRANCH_ROLE_UNASSIGNED',
        detail = format(
          'Legacy branch-scoped assignment %s for staff %s has no branch assignment to map to',
          v_assignment.id,
          v_assignment.staff_id
        ),
        hint = 'For an active assignment, create the intended staff_branch_assignments or revoke it. For an already-revoked assignment with no historical branch assignment, archive or delete the inert row with explicit approval. Never add a branch merely to make the row fit.';
    end if;

    update public.staff_role_assignments
       set branch_id = v_branches[1]
     where id = v_assignment.id;

    if cardinality(v_branches) > 1 then
      for v_index in 2..cardinality(v_branches) loop
        v_branch_id := v_branches[v_index];

        insert into public.staff_role_assignments (
          staff_id,
          organization_id,
          role_code,
          scope_type,
          branch_id,
          assigned_by_staff_id,
          assigned_at,
          revoked_at,
          revoked_by_staff_id,
          reason,
          created_at,
          updated_at
        )
        values (
          v_assignment.staff_id,
          v_assignment.organization_id,
          v_assignment.role_code,
          v_assignment.scope_type,
          v_branch_id,
          v_assignment.assigned_by_staff_id,
          v_assignment.assigned_at,
          v_assignment.revoked_at,
          v_assignment.revoked_by_staff_id,
          v_assignment.reason,
          v_assignment.created_at,
          v_assignment.updated_at
        );
      end loop;
    end if;
  end loop;
end;
$$;

revoke all on function private.backfill_legacy_branch_role_assignments()
  from public;

do $$
declare
  v_role text;
begin
  foreach v_role in array array['service_role', 'authenticated', 'anon'] loop
    if exists (select 1 from pg_roles where rolname = v_role) then
      execute format(
        'revoke all on function private.backfill_legacy_branch_role_assignments() from %I',
        v_role
      );
    end if;
  end loop;
end
$$;

comment on function private.backfill_legacy_branch_role_assignments() is
  'Migration-time helper that splits legacy branch-scoped assignments across their active staff_branch_assignments. Takes a SHARE lock on staff_branch_assignments to keep concurrent branch-assignment changes from interleaving with the split. Fails rather than inventing a branch.';

-- F6: validate a supplied branch for organization-scoped permissions. A null
-- branch means the caller is checking an organization-wide permission without
-- branch context. A non-null branch must be an active branch in the staff
-- member's organization. Branch-scoped permissions always require the matching
-- active branch and an active branch assignment.
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
        (
          sra.scope_type = 'organization'
          and (
            p_branch_id is null
            or exists (
              select 1
              from public.branches b
              where b.id = p_branch_id
                and b.organization_id = sp.organization_id
                and b.status = 'active'
            )
          )
        )
        or (
          p_branch_id is not null
          and sra.scope_type = 'branch'
          and sra.branch_id = p_branch_id
          and exists (
            select 1
            from public.branches b
            where b.id = p_branch_id
              and b.organization_id = sp.organization_id
              and b.status = 'active'
          )
          and exists (
            select 1
            from public.staff_branch_assignments sba
            where sba.staff_id = sp.id
              and sba.organization_id = sp.organization_id
              and sba.branch_id = p_branch_id
              and sba.revoked_at is null
          )
        )
      )
  );
$$;

revoke all on function authz.has_permission(text, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function authz.has_permission(text, uuid) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function authz.has_permission(text, uuid) to service_role';
  end if;
end
$$;

comment on function authz.has_permission(text, uuid) is
  'Fail-closed branch-aware permission check. Organization-scoped roles grant permission when p_branch_id is null or identifies an active branch in the staff organization. Branch-scoped roles require the matching active branch and an active branch assignment. role_permissions remains intentionally empty in the initial release.';
