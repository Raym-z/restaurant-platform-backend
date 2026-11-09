-- M2.1 follow-up: concurrency-safe branch assignment consistency and
-- serialized role revocation.
--
-- This migration is intentionally separate from
-- 20261108120000_m2_branch_scoped_staff_roles.sql so environments that already
-- applied the original migration can receive the fixes without editing an
-- applied migration.
--
-- Fixes:
--   * M-1: the branch-assignment trigger now uses a conflict-safe insert, so
--     concurrent grants of different roles at the same branch do not surface a
--     false RESOURCE_CONFLICT from the branch-assignment unique index.
--   * L-2: revocation locks the assignment row, so concurrent revocations
--     serialize and only one audit event is written.
--   * L-5: adds a full index for the composite branch/organization FK.
--   * L-6: removes unnecessary execute grants on internal helper functions from
--     client-facing/server roles other than the migration owner.

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
    -- The partial unique index staff_branch_assignments_active_unique is the
    -- concurrency backstop. ON CONFLICT DO NOTHING makes a concurrent grant of
    -- a different role at the same branch safe: whichever transaction creates
    -- the assignment first wins, and the other does not raise a unique
    -- violation that the role-grant RPC would misreport as a role conflict.
    insert into public.staff_branch_assignments (
      staff_id,
      organization_id,
      branch_id,
      assigned_by_staff_id
    )
    values (
      new.staff_id,
      new.organization_id,
      new.branch_id,
      new.assigned_by_staff_id
    )
    on conflict (staff_id, branch_id) where revoked_at is null do nothing;
  end if;

  return new;
end;
$$;

revoke all on function private.ensure_staff_branch_assignment_for_role()
  from public;

comment on function private.ensure_staff_branch_assignment_for_role() is
  'Keeps an active branch-scoped role paired with an active staff_branch_assignment. Uses ON CONFLICT DO NOTHING so concurrent role grants at the same branch do not produce false role conflicts. Branch assignments still grant no permission by themselves, and revoking one still denies access.';

-- Serialize concurrent revocations of the same assignment. The second caller
-- blocks on the row lock, then observes revoked_at and returns already_revoked
-- without writing a duplicate audit event.
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
   where sra.id = p_assignment_id
   for update;

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

-- Supports the composite (branch_id, organization_id) foreign key and branch
-- deletion/RI checks. The existing branch/role index is partial on active rows
-- and cannot serve every FK check.
create index if not exists staff_role_assignments_branch_fk_idx
  on public.staff_role_assignments (branch_id, organization_id);

comment on index public.staff_role_assignments_branch_fk_idx is
  'Supports the staff_role_assignments branch/organization foreign key and branch-scoped lookups.';

-- Internal helpers are not client-callable. The migration owner retains
-- execute; service_role and client roles do not need it.
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
      execute format(
        'revoke all on function private.ensure_staff_branch_assignment_for_role() from %I',
        v_role
      );
    end if;
  end loop;
end
$$;
