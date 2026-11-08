-- M2.1 regression tests: per-branch staff role assignments.
--
-- These tests use the real authenticated database role through the shared
-- tests.authenticate_as helper. Fixtures are inserted as the test runner
-- (postgres), then role resolution is evaluated as each staff identity.

begin;

select plan(63);

select has_column(
  'public',
  'staff_role_assignments',
  'branch_id',
  'staff_role_assignments has an explicit branch identifier'
);

select has_index(
  'public',
  'staff_role_assignments',
  'staff_role_assignments_active_organization_role_unique',
  'organization-scoped active assignments have a dedicated uniqueness rule'
);

select has_index(
  'public',
  'staff_role_assignments',
  'staff_role_assignments_active_branch_role_unique',
  'branch-scoped active assignments are unique per branch'
);

select has_index(
  'public',
  'staff_role_assignments',
  'staff_role_assignments_branch_role_active_idx',
  'branch/role lookups have an active partial index'
);

select has_index(
  'public',
  'staff_role_assignments',
  'staff_role_assignments_one_active_owner',
  'the one-active-Owner invariant is retained'
);

-- Fixtures -----------------------------------------------------------------

insert into public.plans (code, name, is_free, branch_limit)
values ('m21_test_plan', 'M2.1 test plan', false, 10);

insert into public.organizations (id, name, default_currency_code)
values (tests.uuid_for('m21-org'), 'M2.1 test organization', 'IDR');

insert into public.branches (id, organization_id, name, timezone)
values
  (tests.uuid_for('m21-branch-a'), tests.uuid_for('m21-org'), 'Branch A', 'Asia/Jakarta'),
  (tests.uuid_for('m21-branch-b'), tests.uuid_for('m21-org'), 'Branch B', 'Asia/Jakarta'),
  (tests.uuid_for('m21-branch-c'), tests.uuid_for('m21-org'), 'Branch C', 'Asia/Jakarta'),
  (tests.uuid_for('m21-branch-d'), tests.uuid_for('m21-org'), 'Branch D', 'Asia/Jakarta');

update public.branches
   set status = 'inactive',
       deactivated_at = now()
 where id = tests.uuid_for('m21-branch-c');

insert into public.organizations (id, name, default_currency_code)
values (tests.uuid_for('m21-other-org'), 'M2.1 other organization', 'IDR');

insert into public.branches (id, organization_id, name, timezone)
values (
  tests.uuid_for('m21-other-branch'),
  tests.uuid_for('m21-other-org'),
  'Other Branch',
  'Asia/Jakarta'
);

insert into public.subscriptions (organization_id, plan_code, state)
values (tests.uuid_for('m21-org'), 'm21_test_plan', 'active');

insert into auth.users (id)
values
  (tests.uuid_for('m21-owner-auth')),
  (tests.uuid_for('m21-multi-auth')),
  (tests.uuid_for('m21-revoked-auth')),
  (tests.uuid_for('m21-inactive-auth')),
  (tests.uuid_for('m21-inactive-branch-auth')),
  (tests.uuid_for('m21-org-admin-auth')),
  (tests.uuid_for('m21-constraint-auth')),
  (tests.uuid_for('m21-legacy-auth')),
  (tests.uuid_for('m21-unassigned-auth')),
  (tests.uuid_for('m21-branch-admin-auth')),
  (tests.uuid_for('m21-assignment-only-auth')),
  (tests.uuid_for('m21-unassigned-revoked-auth'));

insert into public.staff_profiles
  (id, auth_user_id, organization_id, display_name, status, activated_at)
values
  (tests.uuid_for('m21-owner-staff'), tests.uuid_for('m21-owner-auth'), tests.uuid_for('m21-org'), 'Owner', 'active', now()),
  (tests.uuid_for('m21-multi-staff'), tests.uuid_for('m21-multi-auth'), tests.uuid_for('m21-org'), 'Multi', 'active', now()),
  (tests.uuid_for('m21-revoked-staff'), tests.uuid_for('m21-revoked-auth'), tests.uuid_for('m21-org'), 'Revoked', 'active', now()),
  (tests.uuid_for('m21-inactive-staff'), tests.uuid_for('m21-inactive-auth'), tests.uuid_for('m21-org'), 'Inactive', 'active', now()),
  (tests.uuid_for('m21-inactive-branch-staff'), tests.uuid_for('m21-inactive-branch-auth'), tests.uuid_for('m21-org'), 'Inactive branch', 'active', now()),
  (tests.uuid_for('m21-org-admin-staff'), tests.uuid_for('m21-org-admin-auth'), tests.uuid_for('m21-org'), 'Org admin', 'active', now()),
  (tests.uuid_for('m21-constraint-staff'), tests.uuid_for('m21-constraint-auth'), tests.uuid_for('m21-org'), 'Constraint', 'active', now()),
  (tests.uuid_for('m21-legacy-staff'), tests.uuid_for('m21-legacy-auth'), tests.uuid_for('m21-org'), 'Legacy', 'active', now()),
  (tests.uuid_for('m21-unassigned-staff'), tests.uuid_for('m21-unassigned-auth'), tests.uuid_for('m21-org'), 'Unassigned', 'active', now()),
  (tests.uuid_for('m21-branch-admin-staff'), tests.uuid_for('m21-branch-admin-auth'), tests.uuid_for('m21-org'), 'Branch admin', 'active', now()),
  (tests.uuid_for('m21-assignment-only-staff'), tests.uuid_for('m21-assignment-only-auth'), tests.uuid_for('m21-org'), 'Assignment only', 'active', now()),
  (tests.uuid_for('m21-unassigned-revoked-staff'), tests.uuid_for('m21-unassigned-revoked-auth'), tests.uuid_for('m21-org'), 'Revoked unassigned', 'active', now());

-- Branch assignments are inserted before branch-scoped roles so the
-- role/assignment consistency trigger sees an existing active row.
insert into public.staff_branch_assignments
  (staff_id, organization_id, branch_id)
values
  (tests.uuid_for('m21-multi-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-multi-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-b')),
  (tests.uuid_for('m21-inactive-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-inactive-branch-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-c')),
  (tests.uuid_for('m21-constraint-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-legacy-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-legacy-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-b')),
  (tests.uuid_for('m21-branch-admin-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-assignment-only-staff'), tests.uuid_for('m21-org'), tests.uuid_for('m21-branch-a'));

insert into public.staff_role_assignments
  (staff_id, organization_id, role_code, scope_type, branch_id)
values
  (tests.uuid_for('m21-owner-staff'), tests.uuid_for('m21-org'), 'owner', 'organization', null),
  (tests.uuid_for('m21-multi-staff'), tests.uuid_for('m21-org'), 'manager', 'branch', tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-multi-staff'), tests.uuid_for('m21-org'), 'cashier', 'branch', tests.uuid_for('m21-branch-b')),
  (tests.uuid_for('m21-revoked-staff'), tests.uuid_for('m21-org'), 'manager', 'branch', tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-inactive-staff'), tests.uuid_for('m21-org'), 'manager', 'branch', tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-inactive-branch-staff'), tests.uuid_for('m21-org'), 'manager', 'branch', tests.uuid_for('m21-branch-c')),
  (tests.uuid_for('m21-org-admin-staff'), tests.uuid_for('m21-org'), 'admin', 'organization', null),
  (tests.uuid_for('m21-branch-admin-staff'), tests.uuid_for('m21-org'), 'admin', 'branch', tests.uuid_for('m21-branch-a')),
  (tests.uuid_for('m21-constraint-staff'), tests.uuid_for('m21-org'), 'manager', 'branch', tests.uuid_for('m21-branch-a'));

-- The revoked staff member's role insert created the active branch assignment;
-- revoke it to prove a revoked branch assignment denies branch access.
update public.staff_branch_assignments
   set revoked_at = now()
 where staff_id = tests.uuid_for('m21-revoked-staff')
   and branch_id = tests.uuid_for('m21-branch-a');

update public.staff_profiles
   set status = 'deactivated',
       deactivated_at = now()
 where id = tests.uuid_for('m21-inactive-staff');

-- Constraint checks --------------------------------------------------------

select throws_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'manager', 'branch', null)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org')
  ),
  'P0001',
  'INVALID_ROLE_SCOPE',
  'a branch-scoped assignment requires a branch'
);

select throws_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'admin', 'organization', %L)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org'),
    tests.uuid_for('m21-branch-a')
  ),
  'P0001',
  'INVALID_ROLE_SCOPE',
  'an organization-scoped assignment must not include a branch'
);

select throws_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'manager', 'branch', %L)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org'),
    tests.uuid_for('m21-branch-a')
  ),
  '23505',
  null,
  'duplicate active role assignments at the same branch are rejected'
);

select lives_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'manager', 'branch', %L)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org'),
    tests.uuid_for('m21-branch-b')
  ),
  'the same role may be assigned at a different branch'
);

select throws_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'cashier', 'branch', %L)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org'),
    tests.uuid_for('m21-other-branch')
  ),
  '23503',
  null,
  'a branch identifier from another organization is rejected'
);

update public.staff_role_assignments
   set revoked_at = now()
 where staff_id = tests.uuid_for('m21-constraint-staff')
   and role_code = 'manager'
   and branch_id = tests.uuid_for('m21-branch-a')
   and revoked_at is null;

select lives_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'manager', 'branch', %L)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org'),
    tests.uuid_for('m21-branch-a')
  ),
  'a revoked assignment can be replaced without violating active uniqueness'
);

select throws_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'owner', 'organization', null)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org')
  ),
  '23505',
  null,
  'the one-active-Owner invariant remains enforced'
);

select throws_ok(
  format(
    $sql$
      insert into public.staff_role_assignments
        (staff_id, organization_id, role_code, scope_type, branch_id)
      values (%L, %L, 'owner', 'branch', %L)
    $sql$,
    tests.uuid_for('m21-constraint-staff'),
    tests.uuid_for('m21-org'),
    tests.uuid_for('m21-branch-a')
  ),
  'P0001',
  'INVALID_ROLE_SCOPE',
  'Owner cannot be branch-scoped'
);

-- Authorization checks -----------------------------------------------------

select tests.authenticate_as(tests.uuid_for('m21-multi-auth'));

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['manager']::text[]),
  'Manager at Branch A resolves as Manager at Branch A'
);

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['manager']::text[]),
  'Manager at Branch A does not resolve as Manager at Branch B'
);

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['cashier']::text[]),
  'Cashier at Branch B resolves as Cashier at Branch B'
);

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['cashier']::text[]),
  'Cashier at Branch B does not resolve as Cashier at Branch A'
);

select ok(
  authz.has_branch_access(tests.uuid_for('m21-branch-a')),
  'the staff member can access Branch A'
);

select ok(
  authz.has_branch_access(tests.uuid_for('m21-branch-b')),
  'the staff member can access Branch B'
);

select ok(
  not authz.has_org_role(array['owner', 'admin']::text[]),
  'branch-scoped roles do not grant organization administrator authority'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-branch-admin-auth'));

select ok(
  not authz.has_org_role(array['owner', 'admin']::text[]),
  'branch-scoped Admin has no organization administrator authority'
);

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['admin']::text[]),
  'branch-scoped Admin has admin authority at its own branch'
);

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['admin']::text[]),
  'branch-scoped Admin has no admin authority at another branch'
);

select ok(
  not authz.has_branch_access(tests.uuid_for('m21-branch-b')),
  'branch-scoped Admin cannot access another branch'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-assignment-only-auth'));

select ok(
  not authz.has_branch_access(tests.uuid_for('m21-branch-a')),
  'a branch assignment without a role grants no branch access'
);

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['cashier']::text[]),
  'a branch assignment without a role grants no branch role'
);

select ok(
  (select count(*) = 0 from public.branches),
  'a branch assignment without a role exposes no branches'
);

select tests.clear_auth();

insert into public.staff_role_assignments
  (staff_id, organization_id, role_code, scope_type, branch_id)
values
  (tests.uuid_for('m21-assignment-only-staff'), tests.uuid_for('m21-org'),
   'cashier', 'branch', tests.uuid_for('m21-branch-b'));

select ok(
  exists (
    select 1
    from public.staff_branch_assignments
    where staff_id = tests.uuid_for('m21-assignment-only-staff')
      and branch_id = tests.uuid_for('m21-branch-b')
      and revoked_at is null
  ),
  'a direct branch role insert creates the matching branch assignment'
);

select tests.authenticate_as(tests.uuid_for('m21-assignment-only-auth'));

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['cashier']::text[]),
  'a directly inserted branch role resolves at its branch'
);

select tests.clear_auth();

update public.staff_role_assignments
   set branch_id = tests.uuid_for('m21-branch-d')
 where staff_id = tests.uuid_for('m21-assignment-only-staff')
   and role_code = 'cashier'
   and branch_id = tests.uuid_for('m21-branch-b')
   and revoked_at is null;

select ok(
  exists (
    select 1
    from public.staff_branch_assignments
    where staff_id = tests.uuid_for('m21-assignment-only-staff')
      and branch_id = tests.uuid_for('m21-branch-d')
      and revoked_at is null
  ),
  'moving a branch role to a new branch creates the matching branch assignment'
);

select tests.authenticate_as(tests.uuid_for('m21-assignment-only-auth'));

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-d'), array['cashier']::text[]),
  'the moved branch role resolves at the new branch'
);

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['cashier']::text[]),
  'the moved branch role no longer resolves at the old branch'
);

select ok(
  authz.has_branch_access(tests.uuid_for('m21-branch-d')),
  'the moved branch role grants access at the new branch'
);

select ok(
  not authz.has_branch_access(tests.uuid_for('m21-branch-b')),
  'the old branch assignment alone no longer grants access after the role moves'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-inactive-auth'));

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['manager']::text[]),
  'inactive staff are denied branch roles'
);

select ok(
  not authz.has_branch_access(tests.uuid_for('m21-branch-a')),
  'inactive staff are denied branch access'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-inactive-branch-auth'));

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-c'), array['manager']::text[]),
  'inactive branches never resolve branch roles'
);

select ok(
  not authz.has_branch_access(tests.uuid_for('m21-branch-c')),
  'inactive branches never resolve branch access'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-revoked-auth'));

select ok(
  not authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['manager']::text[]),
  'a revoked branch assignment grants no branch role'
);

select ok(
  not authz.has_branch_access(tests.uuid_for('m21-branch-a')),
  'a revoked branch assignment grants no branch access'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-owner-auth'));

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['owner']::text[]),
  'the organization Owner has authority at Branch A'
);

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['owner']::text[]),
  'the organization Owner has authority at Branch B'
);

select ok(
  authz.has_branch_access(tests.uuid_for('m21-branch-a')),
  'the organization Owner can access Branch A without a branch assignment'
);

select ok(
  authz.has_branch_access(tests.uuid_for('m21-branch-b')),
  'the organization Owner can access Branch B without a branch assignment'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-org-admin-auth'));

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-a'), array['admin']::text[]),
  'organization-scoped Admin has authority at Branch A'
);

select ok(
  authz.has_branch_role(tests.uuid_for('m21-branch-b'), array['admin']::text[]),
  'organization-scoped Admin has authority at Branch B'
);

select ok(
  authz.has_org_role(array['admin']::text[]),
  'organization-scoped Admin keeps organization-wide role semantics'
);

select tests.clear_auth();

-- Permission checks ---------------------------------------------------------
-- Seed temporary permission mappings inside this transaction. They are test
-- data, not approved production permission mappings, and roll back with the
-- surrounding test transaction.

insert into public.permissions (code, description)
values
  ('m21.permission.manager', 'M2.1 reviewer test manager permission'),
  ('m21.permission.admin', 'M2.1 reviewer test admin permission');

insert into public.role_permissions (role_code, permission_code)
values
  ('manager', 'm21.permission.manager'),
  ('admin', 'm21.permission.admin');

select tests.authenticate_as(tests.uuid_for('m21-multi-auth'));

select ok(
  authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-a')),
  'branch Manager permission resolves at the assigned branch'
);

select ok(
  not authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-b')),
  'branch Manager permission does not resolve at another branch'
);

select ok(
  not authz.has_permission('m21.permission.admin', tests.uuid_for('m21-branch-a')),
  'branch Manager does not gain Admin permission'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-org-admin-auth'));

select ok(
  authz.has_permission('m21.permission.admin', tests.uuid_for('m21-branch-a')),
  'organization Admin permission resolves at Branch A'
);

select ok(
  authz.has_permission('m21.permission.admin', tests.uuid_for('m21-branch-b')),
  'organization Admin permission resolves at Branch B'
);

select ok(
  not authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-a')),
  'organization Admin does not gain Manager permission'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-assignment-only-auth'));

select ok(
  not authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-a')),
  'a branch role without the permission mapping grants no permission'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-inactive-auth'));

select ok(
  not authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-a')),
  'inactive staff have no branch permission'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-inactive-branch-auth'));

select ok(
  not authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-c')),
  'inactive branches deny branch permissions'
);

select tests.clear_auth();
select tests.authenticate_as(tests.uuid_for('m21-revoked-auth'));

select ok(
  not authz.has_permission('m21.permission.manager', tests.uuid_for('m21-branch-a')),
  'a revoked branch assignment denies branch permission'
);

select tests.clear_auth();

-- Legacy backfill ----------------------------------------------------------
-- Relax the new invariant temporarily to recreate legacy rows, then prove the
-- production backfill helper splits them deterministically and fails closed.

alter table public.staff_role_assignments
  drop constraint staff_role_assignments_branch_scope_check;

alter table public.staff_role_assignments
  disable trigger staff_role_assignments_validate_scope;

insert into public.staff_role_assignments
  (staff_id, organization_id, role_code, scope_type, branch_id)
values
  (tests.uuid_for('m21-legacy-staff'), tests.uuid_for('m21-org'), 'manager', 'branch', null);

select lives_ok(
  'select private.backfill_legacy_branch_role_assignments()',
  'the legacy backfill runs deterministically'
);

select is(
  (
    select count(*)::integer
    from public.staff_role_assignments
    where staff_id = tests.uuid_for('m21-legacy-staff')
      and role_code = 'manager'
      and revoked_at is null
  ),
  2,
  'a legacy assignment with two active branches is split into two branch rows'
);

select ok(
  exists (
    select 1
    from public.staff_role_assignments
    where staff_id = tests.uuid_for('m21-legacy-staff')
      and role_code = 'manager'
      and branch_id = tests.uuid_for('m21-branch-a')
      and revoked_at is null
  ),
  'the legacy assignment preserves Branch A'
);

select ok(
  exists (
    select 1
    from public.staff_role_assignments
    where staff_id = tests.uuid_for('m21-legacy-staff')
      and role_code = 'manager'
      and branch_id = tests.uuid_for('m21-branch-b')
      and revoked_at is null
  ),
  'the legacy assignment preserves Branch B'
);

insert into public.staff_role_assignments
  (staff_id, organization_id, role_code, scope_type, branch_id)
values
  (tests.uuid_for('m21-unassigned-staff'), tests.uuid_for('m21-org'), 'cashier', 'branch', null);

select throws_ok(
  'select private.backfill_legacy_branch_role_assignments()',
  'P0001',
  'LEGACY_BRANCH_ROLE_UNASSIGNED',
  'an unassigned legacy branch role fails closed instead of inventing access'
);

delete from public.staff_role_assignments
 where staff_id = tests.uuid_for('m21-unassigned-staff');

insert into public.staff_role_assignments
  (staff_id, organization_id, role_code, scope_type, branch_id, revoked_at)
values
  (tests.uuid_for('m21-unassigned-revoked-staff'), tests.uuid_for('m21-org'),
   'cashier', 'branch', null, now());

select throws_ok(
  'select private.backfill_legacy_branch_role_assignments()',
  'P0001',
  'LEGACY_BRANCH_ROLE_UNASSIGNED',
  'a revoked legacy branch role with no assignment history fails closed'
);

select * from finish();

rollback;
