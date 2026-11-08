-- Orders, order-item snapshots, modifier snapshots, and pre-finalization discounts.

create table public.session_discounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  dining_session_id uuid not null,
  discount_type public.discount_type not null,
  value_minor bigint,
  percentage_basis_points integer,
  reason text,
  applied_by_staff_id uuid not null,
  applied_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by_staff_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint session_discounts_value_check check (
    (
      discount_type = 'fixed_amount'
      and value_minor is not null
      and value_minor >= 0
      and percentage_basis_points is null
    )
    or (
      discount_type = 'percentage'
      and percentage_basis_points is not null
      and percentage_basis_points >= 0
      and value_minor is null
    )
  ),
  constraint session_discounts_session_branch_organization_fkey
    foreign key (dining_session_id, branch_id, organization_id)
    references public.dining_sessions (id, branch_id, organization_id)
    on delete restrict,
  constraint session_discounts_applied_by_organization_fkey
    foreign key (applied_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint session_discounts_removed_by_organization_fkey
    foreign key (removed_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create index session_discounts_session_active_idx
  on public.session_discounts (dining_session_id)
  where removed_at is null;

create trigger session_discounts_set_updated_at
  before update on public.session_discounts
  for each row execute function private.set_updated_at();

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  dining_session_id uuid not null,
  source public.order_source not null,
  status public.order_status not null default 'pending',
  currency_code text not null
    references public.currencies (code) on delete restrict,
  subtotal_minor bigint not null,
  notes text,
  submitted_by_staff_id uuid,
  current_bill_id uuid,
  accepted_at timestamptz,
  preparing_at timestamptz,
  ready_at timestamptz,
  served_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by_staff_id uuid,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_subtotal_check check (subtotal_minor >= 0),
  constraint orders_source_actor_check check (
    (source = 'guest' and submitted_by_staff_id is null)
    or (source = 'staff' and submitted_by_staff_id is not null)
  ),
  constraint orders_cancellation_timestamp_check
    check (status <> 'cancelled' or cancelled_at is not null),
  constraint orders_id_branch_organization_key
    unique (id, branch_id, organization_id),
  constraint orders_id_organization_branch_session_key
    unique (id, organization_id, branch_id, dining_session_id),
  constraint orders_session_branch_organization_fkey
    foreign key (dining_session_id, branch_id, organization_id)
    references public.dining_sessions (id, branch_id, organization_id)
    on delete restrict,
  constraint orders_submitted_by_organization_fkey
    foreign key (submitted_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint orders_cancelled_by_organization_fkey
    foreign key (cancelled_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create index orders_branch_status_created_idx
  on public.orders (branch_id, status, created_at);

create index orders_dining_session_idx
  on public.orders (dining_session_id);

create index orders_organization_created_idx
  on public.orders (organization_id, created_at);

create index orders_current_bill_idx
  on public.orders (current_bill_id);

create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function private.set_updated_at();

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null,
  organization_id uuid not null,
  branch_id uuid not null,
  menu_item_id uuid not null,
  item_name_snapshot text not null,
  base_unit_price_minor bigint not null,
  modifier_unit_delta_minor bigint not null default 0,
  quantity integer not null,
  effective_unit_price_minor bigint
    generated always as (base_unit_price_minor + modifier_unit_delta_minor) stored,
  line_total_minor bigint
    generated always as (
      (base_unit_price_minor + modifier_unit_delta_minor) * quantity
    ) stored,
  currency_code text not null
    references public.currencies (code) on delete restrict,
  status public.order_item_status not null default 'pending',
  notes text,
  preparing_at timestamptz,
  ready_at timestamptz,
  served_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by_staff_id uuid,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint order_items_base_price_check check (base_unit_price_minor >= 0),
  constraint order_items_quantity_check check (quantity > 0),
  constraint order_items_effective_unit_price_check
    check (base_unit_price_minor + modifier_unit_delta_minor >= 0),
  constraint order_items_cancellation_timestamp_check
    check (status <> 'cancelled' or cancelled_at is not null),
  constraint order_items_id_organization_key unique (id, organization_id),
  constraint order_items_order_branch_organization_fkey
    foreign key (order_id, branch_id, organization_id)
    references public.orders (id, branch_id, organization_id)
    on delete restrict,
  constraint order_items_menu_item_organization_fkey
    foreign key (menu_item_id, organization_id)
    references public.menu_items (id, organization_id)
    on delete restrict,
  constraint order_items_cancelled_by_organization_fkey
    foreign key (cancelled_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create index order_items_order_idx
  on public.order_items (order_id);

create index order_items_branch_status_idx
  on public.order_items (branch_id, status);

create trigger order_items_set_updated_at
  before update on public.order_items
  for each row execute function private.set_updated_at();

create table public.order_item_modifiers (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null,
  organization_id uuid not null,
  modifier_group_id uuid not null,
  modifier_option_id uuid not null,
  group_name_snapshot text not null,
  option_name_snapshot text not null,
  price_delta_minor bigint not null,
  created_at timestamptz not null default now(),
  constraint order_item_modifiers_item_organization_fkey
    foreign key (order_item_id, organization_id)
    references public.order_items (id, organization_id)
    on delete restrict,
  constraint order_item_modifiers_option_group_organization_fkey
    foreign key (modifier_option_id, modifier_group_id, organization_id)
    references public.modifier_options (id, modifier_group_id, organization_id)
    on delete restrict
);

create index order_item_modifiers_order_item_idx
  on public.order_item_modifiers (order_item_id);

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'session_discounts',
    'orders',
    'order_items',
    'order_item_modifiers'
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

comment on table public.orders is
  'Guest orders have no guest-token foreign key. Historical validity comes from dining_sessions; token validity is enforced at submission. Order display numbering is intentionally deferred.';

comment on table public.order_items is
  'base_unit_price_minor and modifier_unit_delta_minor are per-item-unit snapshots. Line total is generated as (base + modifier delta) * quantity. Modifier-sum consistency is an Agent 2 validation boundary.';

comment on table public.order_item_modifiers is
  'Historical modifier snapshots. No independent modifier quantity is implemented initially.';

comment on table public.session_discounts is
  'Pre-finalization discount inputs. Finalized bill discounts are snapshotted separately. Stacking rules remain Agent 2 business logic.';
