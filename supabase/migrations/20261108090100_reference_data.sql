-- Reference and lookup data.
--
-- Only approved reference values are seeded here:
--   * IDR currency (minor unit exponent 0)
--   * The five initial organization roles
--
-- Plans, plan entitlements, permissions, and role-permission mappings are
-- intentionally not seeded until their catalogs are approved.

create table public.currencies (
  code text primary key,
  name text not null,
  minor_unit_exponent smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint currencies_code_format_check check (code ~ '^[A-Z]{3}$'),
  constraint currencies_minor_unit_exponent_check
    check (minor_unit_exponent between 0 and 4)
);

create table public.plans (
  code text primary key,
  name text not null,
  is_free boolean not null default false,
  branch_limit integer,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint plans_branch_limit_check
    check (branch_limit is null or branch_limit > 0)
);

create unique index plans_one_active_free_plan
  on public.plans ((is_free))
  where is_free and is_active;

create table public.plan_entitlements (
  id uuid primary key default gen_random_uuid(),
  plan_code text not null references public.plans (code) on delete restrict,
  entitlement_key text not null,
  value jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint plan_entitlements_plan_key_unique unique (plan_code, entitlement_key)
);

create table public.organization_roles (
  code text primary key,
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  constraint organization_roles_initial_set_check
    check (code in ('owner', 'admin', 'manager', 'cashier', 'kitchen_staff'))
);

create table public.permissions (
  code text primary key,
  description text,
  created_at timestamptz not null default now()
);

create table public.role_permissions (
  role_code text not null
    references public.organization_roles (code) on delete restrict,
  permission_code text not null
    references public.permissions (code) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (role_code, permission_code)
);

insert into public.currencies (code, name, minor_unit_exponent)
values ('IDR', 'Indonesian Rupiah', 0)
on conflict (code) do nothing;

insert into public.organization_roles (code, name, description)
values
  ('owner', 'Owner', 'Organization-wide authority. Exactly one active Owner per organization.'),
  ('admin', 'Admin', 'Organization administration; scope is explicit (organization-wide or assigned branches).'),
  ('manager', 'Manager', 'Operational management within assigned branches.'),
  ('cashier', 'Cashier', 'Cashier and payment workflows within assigned branches.'),
  ('kitchen_staff', 'Kitchen Staff', 'Kitchen and preparation workflows within assigned branches.')
on conflict (code) do nothing;

create index plan_entitlements_plan_code_idx
  on public.plan_entitlements (plan_code);

create index role_permissions_permission_code_idx
  on public.role_permissions (permission_code);

create trigger currencies_set_updated_at
  before update on public.currencies
  for each row execute function private.set_updated_at();

create trigger plans_set_updated_at
  before update on public.plans
  for each row execute function private.set_updated_at();

create trigger plan_entitlements_set_updated_at
  before update on public.plan_entitlements
  for each row execute function private.set_updated_at();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'currencies',
    'plans',
    'plan_entitlements',
    'organization_roles',
    'permissions',
    'role_permissions'
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

comment on table public.organization_roles is
  'Exactly five initial roles. Host/Queue Staff is explicitly out of initial scope.';

comment on table public.plans is
  'Plan catalog is intentionally empty until approved. Free plan is confirmed conceptually but its code and seed values require approval.';

comment on table public.role_permissions is
  'Permission matrix is intentionally empty until approved. Agent 2 owns authorization helpers and policies.';
