-- Staff, customer, platform-admin, and organization access structures.

create table public.staff_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique
    references auth.users (id) on delete restrict,
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  display_name text not null,
  status public.staff_status not null default 'invited',
  invited_at timestamptz,
  activated_at timestamptz,
  deactivated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_profiles_id_organization_key unique (id, organization_id),
  constraint staff_profiles_deactivation_timestamp_check
    check (status <> 'deactivated' or deactivated_at is not null)
);

create index staff_profiles_organization_status_idx
  on public.staff_profiles (organization_id, status);

create trigger staff_profiles_set_updated_at
  before update on public.staff_profiles
  for each row execute function private.set_updated_at();

create table public.staff_role_assignments (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null,
  organization_id uuid not null,
  role_code text not null
    references public.organization_roles (code) on delete restrict,
  scope_type public.role_scope not null,
  assigned_by_staff_id uuid,
  assigned_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by_staff_id uuid,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_role_assignments_staff_organization_fkey
    foreign key (staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint staff_role_assignments_assigned_by_organization_fkey
    foreign key (assigned_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint staff_role_assignments_revoked_by_organization_fkey
    foreign key (revoked_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create unique index staff_role_assignments_one_active_owner
  on public.staff_role_assignments (organization_id)
  where role_code = 'owner' and revoked_at is null;

create unique index staff_role_assignments_active_role_unique
  on public.staff_role_assignments (staff_id, role_code, scope_type)
  where revoked_at is null;

create index staff_role_assignments_organization_role_active_idx
  on public.staff_role_assignments (organization_id, role_code)
  where revoked_at is null;

create index staff_role_assignments_staff_active_idx
  on public.staff_role_assignments (staff_id)
  where revoked_at is null;

create trigger staff_role_assignments_validate_scope
  before insert or update of role_code, scope_type
  on public.staff_role_assignments
  for each row execute function private.validate_role_scope();

create trigger staff_role_assignments_set_updated_at
  before update on public.staff_role_assignments
  for each row execute function private.set_updated_at();

create table public.staff_branch_assignments (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null,
  organization_id uuid not null,
  branch_id uuid not null,
  assigned_by_staff_id uuid,
  assigned_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_branch_assignments_staff_organization_fkey
    foreign key (staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint staff_branch_assignments_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict,
  constraint staff_branch_assignments_assigned_by_organization_fkey
    foreign key (assigned_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create unique index staff_branch_assignments_active_unique
  on public.staff_branch_assignments (staff_id, branch_id)
  where revoked_at is null;

create index staff_branch_assignments_branch_active_idx
  on public.staff_branch_assignments (branch_id)
  where revoked_at is null;

create index staff_branch_assignments_staff_idx
  on public.staff_branch_assignments (staff_id);

create trigger staff_branch_assignments_set_updated_at
  before update on public.staff_branch_assignments
  for each row execute function private.set_updated_at();

create table public.customer_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique
    references auth.users (id) on delete restrict,
  full_name text,
  phone text,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger customer_profiles_set_updated_at
  before update on public.customer_profiles
  for each row execute function private.set_updated_at();

create table public.platform_admins (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique
    references auth.users (id) on delete restrict,
  created_by_platform_admin_id uuid
    references public.platform_admins (id) on delete restrict,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  updated_at timestamptz not null default now()
);

create trigger platform_admins_set_updated_at
  before update on public.platform_admins
  for each row execute function private.set_updated_at();

create table public.exceptional_access_grants (
  id uuid primary key default gen_random_uuid(),
  platform_admin_id uuid not null
    references public.platform_admins (id) on delete restrict,
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  scope text not null,
  reason text not null,
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by_platform_admin_id uuid
    references public.platform_admins (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint exceptional_access_grants_expiry_check
    check (expires_at > starts_at)
);

create index exceptional_access_grants_organization_active_idx
  on public.exceptional_access_grants (organization_id, expires_at)
  where revoked_at is null;

create index exceptional_access_grants_platform_admin_idx
  on public.exceptional_access_grants (platform_admin_id);

create trigger exceptional_access_grants_set_updated_at
  before update on public.exceptional_access_grants
  for each row execute function private.set_updated_at();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'staff_profiles',
    'staff_role_assignments',
    'staff_branch_assignments',
    'customer_profiles',
    'platform_admins',
    'exceptional_access_grants'
  ]
  loop
    execute format('alter table public.%I enable row level security', table_name);

    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on public.%I from anon', table_name);
    end if;

    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on public.%I from authenticated', table_name);
    end if;
  end loop;
end
$$;

comment on index public.staff_role_assignments_one_active_owner is
  'At most one active Owner per organization. Agent 2 must also prevent loss of the last active Owner through role revocation, staff deactivation, or account operations.';

comment on table public.staff_role_assignments is
  'Role/scope assignments. At most one active Owner is a database invariant; last-owner preservation is an Agent 2 authorization/workflow invariant.';

comment on table public.staff_branch_assignments is
  'Branch assignments delimit branch-scoped roles. They grant no permission by themselves and do not reduce organization-scoped role reach.';

comment on table public.platform_admins is
  'Platform-admin provisioning occurs outside public registration. Exceptional business-data access requires exceptional_access_grants.';

comment on table public.exceptional_access_grants is
  'Scope vocabulary and authorization remain pending Agent 2 implementation.';
