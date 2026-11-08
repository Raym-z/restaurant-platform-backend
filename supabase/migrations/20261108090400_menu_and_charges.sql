-- Menu, branch availability/pricing, modifiers, and charge configuration.
--
-- Branch availability semantics are intentionally not encoded as a default.
-- The tables support explicit opt-in and default-available contracts; the
-- approved resolution rule is owned by Agent 2 and documented in
-- docs/schema/database-foundation.md.

create table public.menu_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  name text not null,
  description text,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint menu_categories_id_organization_key unique (id, organization_id)
);

create index menu_categories_organization_sort_idx
  on public.menu_categories (organization_id, sort_order)
  where archived_at is null;

create trigger menu_categories_set_updated_at
  before update on public.menu_categories
  for each row execute function private.set_updated_at();

create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  category_id uuid not null,
  name text not null,
  description text,
  base_price_minor bigint not null,
  currency_code text not null
    references public.currencies (code) on delete restrict,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint menu_items_base_price_check check (base_price_minor >= 0),
  constraint menu_items_id_organization_key unique (id, organization_id),
  constraint menu_items_category_organization_fkey
    foreign key (category_id, organization_id)
    references public.menu_categories (id, organization_id)
    on delete restrict
);

create index menu_items_organization_category_idx
  on public.menu_items (organization_id, category_id)
  where archived_at is null;

create trigger menu_items_set_updated_at
  before update on public.menu_items
  for each row execute function private.set_updated_at();

create table public.branch_menu_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  menu_category_id uuid not null,
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_menu_categories_branch_category_unique
    unique (branch_id, menu_category_id),
  constraint branch_menu_categories_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict,
  constraint branch_menu_categories_category_organization_fkey
    foreign key (menu_category_id, organization_id)
    references public.menu_categories (id, organization_id)
    on delete restrict
);

create index branch_menu_categories_branch_available_idx
  on public.branch_menu_categories (branch_id, is_available);

create trigger branch_menu_categories_set_updated_at
  before update on public.branch_menu_categories
  for each row execute function private.set_updated_at();

create table public.branch_menu_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  menu_item_id uuid not null,
  is_available boolean not null default true,
  price_override_minor bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_menu_items_override_price_check
    check (price_override_minor is null or price_override_minor >= 0),
  constraint branch_menu_items_branch_item_unique
    unique (branch_id, menu_item_id),
  constraint branch_menu_items_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict,
  constraint branch_menu_items_item_organization_fkey
    foreign key (menu_item_id, organization_id)
    references public.menu_items (id, organization_id)
    on delete restrict
);

create index branch_menu_items_branch_available_idx
  on public.branch_menu_items (branch_id, is_available);

create index branch_menu_items_menu_item_idx
  on public.branch_menu_items (menu_item_id);

create trigger branch_menu_items_set_updated_at
  before update on public.branch_menu_items
  for each row execute function private.set_updated_at();

create table public.modifier_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  name text not null,
  description text,
  min_selections smallint not null default 0,
  max_selections smallint not null default 1,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint modifier_groups_min_selections_check check (min_selections >= 0),
  constraint modifier_groups_max_selections_check check (max_selections >= 1),
  constraint modifier_groups_selection_range_check
    check (min_selections <= max_selections),
  constraint modifier_groups_id_organization_key unique (id, organization_id)
);

create index modifier_groups_organization_idx
  on public.modifier_groups (organization_id)
  where archived_at is null;

create trigger modifier_groups_set_updated_at
  before update on public.modifier_groups
  for each row execute function private.set_updated_at();

create table public.modifier_options (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  modifier_group_id uuid not null,
  name text not null,
  price_delta_minor bigint not null default 0,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint modifier_options_id_organization_key unique (id, organization_id),
  constraint modifier_options_id_group_organization_key
    unique (id, modifier_group_id, organization_id),
  constraint modifier_options_group_organization_fkey
    foreign key (modifier_group_id, organization_id)
    references public.modifier_groups (id, organization_id)
    on delete restrict
);

create index modifier_options_group_sort_idx
  on public.modifier_options (modifier_group_id, sort_order)
  where archived_at is null;

create trigger modifier_options_set_updated_at
  before update on public.modifier_options
  for each row execute function private.set_updated_at();

create table public.menu_item_modifier_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  menu_item_id uuid not null,
  modifier_group_id uuid not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint menu_item_modifier_groups_item_group_unique
    unique (menu_item_id, modifier_group_id),
  constraint menu_item_modifier_groups_item_organization_fkey
    foreign key (menu_item_id, organization_id)
    references public.menu_items (id, organization_id)
    on delete restrict,
  constraint menu_item_modifier_groups_group_organization_fkey
    foreign key (modifier_group_id, organization_id)
    references public.modifier_groups (id, organization_id)
    on delete restrict
);

create index menu_item_modifier_groups_group_idx
  on public.menu_item_modifier_groups (modifier_group_id);

create table public.organization_charge_configurations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  charge_type public.charge_type not null,
  calculation_type public.calculation_type not null,
  rate_basis_points integer,
  fixed_amount_minor bigint,
  is_enabled boolean not null,
  name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_charge_configurations_type_unique
    unique (organization_id, charge_type),
  constraint organization_charge_configurations_value_check check (
    (
      calculation_type = 'percentage'
      and rate_basis_points is not null
      and rate_basis_points >= 0
      and fixed_amount_minor is null
    )
    or (
      calculation_type = 'fixed_amount'
      and fixed_amount_minor is not null
      and fixed_amount_minor >= 0
      and rate_basis_points is null
    )
  )
);

create trigger organization_charge_configurations_set_updated_at
  before update on public.organization_charge_configurations
  for each row execute function private.set_updated_at();

create table public.branch_charge_configurations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  charge_type public.charge_type not null,
  calculation_type public.calculation_type not null,
  rate_basis_points integer,
  fixed_amount_minor bigint,
  is_enabled boolean not null,
  name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_charge_configurations_branch_type_unique
    unique (branch_id, charge_type),
  constraint branch_charge_configurations_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict,
  constraint branch_charge_configurations_value_check check (
    (
      calculation_type = 'percentage'
      and rate_basis_points is not null
      and rate_basis_points >= 0
      and fixed_amount_minor is null
    )
    or (
      calculation_type = 'fixed_amount'
      and fixed_amount_minor is not null
      and fixed_amount_minor >= 0
      and rate_basis_points is null
    )
  )
);

create index branch_charge_configurations_branch_idx
  on public.branch_charge_configurations (branch_id);

create trigger branch_charge_configurations_set_updated_at
  before update on public.branch_charge_configurations
  for each row execute function private.set_updated_at();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'menu_categories',
    'menu_items',
    'branch_menu_categories',
    'branch_menu_items',
    'modifier_groups',
    'modifier_options',
    'menu_item_modifier_groups',
    'organization_charge_configurations',
    'branch_charge_configurations'
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

comment on table public.branch_menu_categories is
  'Branch-specific category availability. Whether rows are required (opt-in) or optional (default-available) is unresolved and owned by Agent 2.';

comment on table public.branch_menu_items is
  'Branch-specific item availability and optional price override. Row-presence semantics are intentionally not encoded as a database default.';

comment on table public.modifier_options is
  'price_delta_minor sign policy is unresolved. Negative deltas are currently permitted by the schema and must be validated by Agent 2.';

comment on table public.organization_charge_configurations is
  'Stores tax/service-charge configuration only. Calculation base, ordering, inclusivity, and rounding remain unresolved.';
