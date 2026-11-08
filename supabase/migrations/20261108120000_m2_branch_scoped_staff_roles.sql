-- M2.1: per-branch staff role assignments.
--
-- A role assignment is either:
--   * organization-scoped: branch_id IS NULL, or
--   * branch-scoped:       branch_id references one branch in the same
--                          organization as the staff member.
--
-- This migration also replaces the legacy uniqueness rule that allowed only
-- one active branch-scoped assignment per (staff, role), with per-branch
-- uniqueness. A staff member may therefore be Manager at Branch A and Cashier
-- at Branch B, but must not have two active assignments for the same role at
-- the same branch.
--
-- Legacy branch-scoped assignments had no branch_id and applied to every
-- active staff_branch_assignment. The deterministic backfill below preserves
-- that exact effective reach by splitting each legacy assignment into one
-- explicit branch-scoped assignment per active branch assignment. It never
-- invents a branch or widens access. Legacy rows with no branch assignment
-- cannot be represented safely and abort the migration for manual
-- reconciliation; see docs/schema/database-foundation.md §5.
--
-- Apply this migration inside a transaction, as Supabase does. The fail-closed
-- backfill relies on DDL and data changes rolling back together if an
-- unassigned legacy row is encountered; do not run it with per-statement
-- autocommit.

alter table public.staff_role_assignments
  add column branch_id uuid;

alter table public.staff_role_assignments
  add constraint staff_role_assignments_branch_organization_fkey
  foreign key (branch_id, organization_id)
  references public.branches (id, organization_id)
  on delete restrict;

drop index if exists public.staff_role_assignments_active_role_unique;

-- Migration/reconciliation helper. It is intentionally not granted to any
-- client role. The migration invokes it once; the pgTAP backfill test invokes
-- it against a temporarily relaxed constraint to prove the deterministic
-- split behavior.
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

select private.backfill_legacy_branch_role_assignments();

alter table public.staff_role_assignments
  add constraint staff_role_assignments_branch_scope_check
  check (
    (scope_type = 'organization' and branch_id is null)
    or (scope_type = 'branch' and branch_id is not null)
  );

create unique index staff_role_assignments_active_organization_role_unique
  on public.staff_role_assignments (staff_id, role_code)
  where revoked_at is null
    and scope_type = 'organization'
    and branch_id is null;

create unique index staff_role_assignments_active_branch_role_unique
  on public.staff_role_assignments (staff_id, role_code, branch_id)
  where revoked_at is null
    and scope_type = 'branch'
    and branch_id is not null;

create index staff_role_assignments_branch_role_active_idx
  on public.staff_role_assignments (organization_id, branch_id, role_code)
  where revoked_at is null
    and branch_id is not null;

drop trigger if exists staff_role_assignments_validate_scope
  on public.staff_role_assignments;

create trigger staff_role_assignments_validate_scope
  before insert or update of role_code, scope_type, branch_id
  on public.staff_role_assignments
  for each row execute function private.validate_role_scope();

-- A branch-scoped role and its branch assignment are both authorization gates.
-- Keep them consistent automatically: any active branch-scoped role ensures an
-- active staff_branch_assignment for the same staff/branch. This does not grant
-- a branch beyond the explicitly assigned role, and revoking the branch
-- assignment still removes access even while the role row remains active.
create or replace function private.ensure_staff_branch_assignment_for_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.scope_type = 'branch'
     and new.branch_id is not null
     and new.revoked_at is null
  then
    insert into public.staff_branch_assignments (
      staff_id,
      organization_id,
      branch_id,
      assigned_by_staff_id
    )
    select
      new.staff_id,
      new.organization_id,
      new.branch_id,
      new.assigned_by_staff_id
    where not exists (
      select 1
      from public.staff_branch_assignments sba
      where sba.staff_id = new.staff_id
        and sba.organization_id = new.organization_id
        and sba.branch_id = new.branch_id
        and sba.revoked_at is null
    );
  end if;

  return new;
end;
$$;

create trigger staff_role_assignments_ensure_branch_assignment
  after insert or update of branch_id, scope_type, revoked_at
  on public.staff_role_assignments
  for each row execute function private.ensure_staff_branch_assignment_for_role();

revoke all on function private.ensure_staff_branch_assignment_for_role()
  from public;

comment on function private.ensure_staff_branch_assignment_for_role() is
  'Keeps an active branch-scoped role paired with an active staff_branch_assignment. Branch assignments still grant no permission by themselves, and revoking one still denies access.';

create or replace function private.validate_role_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.role_code is null
     or new.role_code not in ('owner', 'admin', 'manager', 'cashier', 'kitchen_staff')
  then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.role_code = 'owner'
     and (new.scope_type <> 'organization' or new.branch_id is not null)
  then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.role_code = 'admin'
     and (
       (new.scope_type = 'organization' and new.branch_id is not null)
       or (new.scope_type = 'branch' and new.branch_id is null)
     )
  then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.role_code in ('manager', 'cashier', 'kitchen_staff')
     and (new.scope_type <> 'branch' or new.branch_id is null)
  then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.scope_type = 'organization' and new.branch_id is not null then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.scope_type = 'branch' and new.branch_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  return new;
end;
$$;

revoke all on function private.validate_role_scope() from public;

comment on column public.staff_role_assignments.branch_id is
  'NULL for organization-scoped assignments. For branch-scoped assignments, references branches(id, organization_id) so the branch and staff member always share an organization.';

comment on constraint staff_role_assignments_branch_organization_fkey
  on public.staff_role_assignments is
  'Prevents a branch-scoped role assignment from referencing a branch in another organization.';

comment on constraint staff_role_assignments_branch_scope_check
  on public.staff_role_assignments is
  'Organization-scoped assignments have no branch; branch-scoped assignments require exactly one branch.';

comment on index public.staff_role_assignments_active_organization_role_unique is
  'At most one active organization-scoped assignment per staff member and role.';

comment on index public.staff_role_assignments_active_branch_role_unique is
  'At most one active branch-scoped assignment per staff member, role, and branch. Different branches may carry different roles.';

comment on function private.backfill_legacy_branch_role_assignments() is
  'Migration-time helper that splits legacy branch-scoped assignments across their active staff_branch_assignments. Fails rather than inventing a branch for an unassigned legacy row.';

-- Role resolution helpers. Branch-scoped roles now apply only when the
-- assignment's branch_id equals the branch being checked. The active
-- staff_branch_assignment gate remains: branch assignments grant no permission
-- by themselves and a branch-scoped role requires both records.
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
            and sra.organization_id = b.organization_id
            and sra.revoked_at is null
            and sra.scope_type = 'organization'
        )
        or (
          exists (
            select 1
            from public.staff_role_assignments sra
            where sra.staff_id = sp.id
              and sra.organization_id = b.organization_id
              and sra.revoked_at is null
              and sra.scope_type = 'branch'
              and sra.branch_id = b.id
          )
          and exists (
            select 1
            from public.staff_branch_assignments sba
            where sba.staff_id = sp.id
              and sba.organization_id = b.organization_id
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
        or (
          sra.scope_type = 'branch'
          and sra.branch_id = b.id
          and exists (
            select 1
            from public.staff_branch_assignments sba
            where sba.staff_id = sp.id
              and sba.organization_id = b.organization_id
              and sba.branch_id = b.id
              and sba.revoked_at is null
          )
        )
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

comment on function authz.has_branch_access(uuid) is
  'True when the active staff member has an organization-scoped role or a branch-scoped role specifically assigned to this active branch plus an active branch assignment.';

comment on function authz.has_branch_role(uuid, text[]) is
  'True when one of the requested roles is organization-scoped or is branch-scoped to exactly this active branch. A branch role never grants access at another branch.';

comment on function authz.has_permission(text, uuid) is
  'Permission checks remain fail-closed while public.role_permissions is empty. Branch-scoped role permissions require the matching branch_id and active branch assignment.';

-- Role assignment RPC. p_branch_id is appended so existing organization-scoped
-- callers that pass p_reason positionally keep working. Branch-scoped callers
-- must supply p_branch_id; the ensure trigger above records the matching active
-- staff_branch_assignment when it does not already exist. The branch assignment
-- remains the access gate and the role assignment remains the permission grant.
drop function if exists public.grant_staff_role(
  uuid,
  text,
  public.role_scope,
  text
);

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

  if v_target_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member belongs to another organization');
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

    if v_branch_org_id is null or v_branch_org_id is distinct from v_actor_org_id then
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

-- Keep revocation audit metadata branch-aware.
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
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

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

