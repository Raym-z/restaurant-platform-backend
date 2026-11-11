-- M4.1: Kitchen Display System (KDS) infrastructure.
--
-- Scope: branch-scoped kitchen stations, menu routing, and kitchen tickets.
-- Ticket generation and ticket lifecycle RPCs are intentionally deferred to
-- M4.2; this migration only creates the storage and authorization foundation.
--
-- Design decisions are documented in docs/m4-kitchen-infrastructure.md.

create type public.kitchen_station_status as enum (
  'active',
  'inactive'
);

create type public.kitchen_ticket_status as enum (
  'pending',
  'preparing',
  'ready',
  'completed',
  'cancelled'
);

-- Stations are branch-scoped configuration. A station name is unique within a
-- branch using a case-insensitive, trimmed comparison so operators cannot
-- create visually duplicate stations.
create table public.kitchen_stations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  name text not null,
  description text,
  status public.kitchen_station_status not null default 'active',
  deactivated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kitchen_stations_name_check
    check (nullif(btrim(name), '') is not null),
  constraint kitchen_stations_status_timestamp_check check (
    (status = 'active' and deactivated_at is null)
    or (status = 'inactive' and deactivated_at is not null)
  ),
  constraint kitchen_stations_id_branch_organization_key
    unique (id, branch_id, organization_id),
  constraint kitchen_stations_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict
);

create unique index kitchen_stations_branch_name_unique
  on public.kitchen_stations (branch_id, lower(btrim(name)));

create index kitchen_stations_branch_status_idx
  on public.kitchen_stations (branch_id, status);

create index kitchen_stations_organization_idx
  on public.kitchen_stations (organization_id);

create trigger kitchen_stations_set_updated_at
  before update on public.kitchen_stations
  for each row execute function private.set_updated_at();

-- Category-level routing. A category route applies to menu items in that
-- category unless the item has an item-level route (see the item table below).
create table public.kitchen_station_menu_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  station_id uuid not null,
  menu_category_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kitchen_station_menu_categories_station_category_unique
    unique (station_id, menu_category_id),
  constraint kitchen_station_menu_categories_station_fkey
    foreign key (station_id, branch_id, organization_id)
    references public.kitchen_stations (id, branch_id, organization_id)
    on delete restrict,
  constraint kitchen_station_menu_categories_category_organization_fkey
    foreign key (menu_category_id, organization_id)
    references public.menu_categories (id, organization_id)
    on delete restrict
);

create index kitchen_station_menu_categories_branch_station_idx
  on public.kitchen_station_menu_categories (branch_id, station_id);

create index kitchen_station_menu_categories_category_idx
  on public.kitchen_station_menu_categories (menu_category_id);

create trigger kitchen_station_menu_categories_set_updated_at
  before update on public.kitchen_station_menu_categories
  for each row execute function private.set_updated_at();

-- Item-level routing. Item routes are the explicit station mapping for one
-- menu item and take precedence over category routes in the M4.2 resolver.
create table public.kitchen_station_menu_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  station_id uuid not null,
  menu_item_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kitchen_station_menu_items_station_item_unique
    unique (station_id, menu_item_id),
  constraint kitchen_station_menu_items_station_fkey
    foreign key (station_id, branch_id, organization_id)
    references public.kitchen_stations (id, branch_id, organization_id)
    on delete restrict,
  constraint kitchen_station_menu_items_item_organization_fkey
    foreign key (menu_item_id, organization_id)
    references public.menu_items (id, organization_id)
    on delete restrict
);

create index kitchen_station_menu_items_branch_station_idx
  on public.kitchen_station_menu_items (branch_id, station_id);

create index kitchen_station_menu_items_item_idx
  on public.kitchen_station_menu_items (menu_item_id);

create trigger kitchen_station_menu_items_set_updated_at
  before update on public.kitchen_station_menu_items
  for each row execute function private.set_updated_at();

-- One ticket per (order, station). The unique key is the idempotency anchor
-- for M4.2 generation: insert ... on conflict (order_id, station_id) do ... .
create table public.kitchen_tickets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  order_id uuid not null,
  station_id uuid not null,
  status public.kitchen_ticket_status not null default 'pending',
  started_at timestamptz,
  ready_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by_staff_id uuid,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kitchen_tickets_cancellation_check check (
    status <> 'cancelled'
    or (
      cancelled_at is not null
      and cancelled_by_staff_id is not null
      and nullif(btrim(cancellation_reason), '') is not null
    )
  ),
  constraint kitchen_tickets_order_station_unique
    unique (order_id, station_id),
  constraint kitchen_tickets_id_order_branch_organization_key
    unique (id, order_id, branch_id, organization_id),
  constraint kitchen_tickets_order_fkey
    foreign key (order_id, branch_id, organization_id)
    references public.orders (id, branch_id, organization_id)
    on delete restrict,
  constraint kitchen_tickets_station_fkey
    foreign key (station_id, branch_id, organization_id)
    references public.kitchen_stations (id, branch_id, organization_id)
    on delete restrict,
  constraint kitchen_tickets_cancelled_by_organization_fkey
    foreign key (cancelled_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create index kitchen_tickets_branch_status_created_idx
  on public.kitchen_tickets (branch_id, status, created_at);

create index kitchen_tickets_station_status_created_idx
  on public.kitchen_tickets (station_id, status, created_at);

create index kitchen_tickets_order_idx
  on public.kitchen_tickets (order_id);

create trigger kitchen_tickets_set_updated_at
  before update on public.kitchen_tickets
  for each row execute function private.set_updated_at();

-- Composite key required so ticket items can prove that their order item
-- belongs to the ticket's order, branch, and organization.
alter table public.order_items
  add constraint order_items_id_order_branch_organization_key
  unique (id, order_id, branch_id, organization_id);

-- Ticket items link a ticket to immutable order-item snapshots. The composite
-- foreign keys make cross-order and cross-tenant links impossible at the
-- database layer, independent of any RPC validation.
create table public.kitchen_ticket_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  ticket_id uuid not null,
  order_id uuid not null,
  order_item_id uuid not null,
  created_at timestamptz not null default now(),
  constraint kitchen_ticket_items_ticket_item_unique
    unique (ticket_id, order_item_id),
  constraint kitchen_ticket_items_ticket_order_fkey
    foreign key (ticket_id, order_id, branch_id, organization_id)
    references public.kitchen_tickets (id, order_id, branch_id, organization_id)
    on delete restrict,
  constraint kitchen_ticket_items_order_item_fkey
    foreign key (order_item_id, order_id, branch_id, organization_id)
    references public.order_items (id, order_id, branch_id, organization_id)
    on delete restrict
);

create index kitchen_ticket_items_ticket_idx
  on public.kitchen_ticket_items (ticket_id);

create index kitchen_ticket_items_order_item_idx
  on public.kitchen_ticket_items (order_item_id);

-- RLS: kitchen data is readable only by Owner/Admin/Manager/Kitchen Staff with
-- access to the branch. Cashier is intentionally excluded. Writes remain
-- RPC-only; no authenticated INSERT/UPDATE/DELETE grants are added.
do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'kitchen_stations',
    'kitchen_station_menu_categories',
    'kitchen_station_menu_items',
    'kitchen_tickets',
    'kitchen_ticket_items'
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

grant select on public.kitchen_stations to authenticated;
grant select on public.kitchen_station_menu_categories to authenticated;
grant select on public.kitchen_station_menu_items to authenticated;
grant select on public.kitchen_tickets to authenticated;
grant select on public.kitchen_ticket_items to authenticated;

create policy kitchen_stations_select_kitchen_roles
  on public.kitchen_stations for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
    )
  );

create policy kitchen_station_menu_categories_select_kitchen_roles
  on public.kitchen_station_menu_categories for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
    )
  );

create policy kitchen_station_menu_items_select_kitchen_roles
  on public.kitchen_station_menu_items for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
    )
  );

create policy kitchen_tickets_select_kitchen_roles
  on public.kitchen_tickets for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
    )
  );

create policy kitchen_ticket_items_select_kitchen_roles
  on public.kitchen_ticket_items for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
    )
  );

comment on table public.kitchen_stations is
  'Branch-scoped kitchen stations. Station names are unique per branch using a case-insensitive trimmed comparison. Inactive stations remain addressable by historical tickets.';

comment on column public.kitchen_stations.status is
  'Active stations participate in future ticket routing; inactive stations keep their configuration and historical tickets but are skipped by the M4.2 resolver.';

comment on table public.kitchen_station_menu_categories is
  'Category-level kitchen routing. Applies to items in the category unless the item has an item-level route.';

comment on table public.kitchen_station_menu_items is
  'Item-level kitchen routing. Takes precedence over category-level routing in the M4.2 resolver.';

comment on table public.kitchen_tickets is
  'One kitchen ticket per (order, station). The unique (order_id, station_id) key is the M4.2 idempotent generation anchor. Multiple stations per order are represented by multiple tickets.';

comment on table public.kitchen_ticket_items is
  'Links a kitchen ticket to immutable order-item snapshots. Composite foreign keys guarantee the item belongs to the ticket order, branch, and organization.';

comment on constraint order_items_id_order_branch_organization_key
  on public.order_items is
  'Order item identity key used by kitchen ticket items to prove order, branch, and organization consistency.';
