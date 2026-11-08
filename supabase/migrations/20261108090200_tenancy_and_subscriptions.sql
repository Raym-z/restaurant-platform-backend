-- Organization, branch, and subscription structures.

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  default_currency_code text not null
    references public.currencies (code) on delete restrict,
  status public.organization_status not null default 'active',
  deletion_requested_at timestamptz,
  deletion_scheduled_for timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_deletion_state_check check (
    status <> 'pending_deletion'
    or (deletion_requested_at is not null and deletion_scheduled_for is not null)
  ),
  constraint organizations_deletion_schedule_check check (
    deletion_scheduled_for is null
    or deletion_requested_at is null
    or deletion_scheduled_for >= deletion_requested_at
  ),
  constraint organizations_deleted_status_check check (
    deleted_at is null or status = 'pending_deletion'
  )
);

create index organizations_status_deleted_idx
  on public.organizations (status, deleted_at);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations (id) on delete restrict,
  name text not null,
  timezone text not null,
  status public.branch_status not null default 'active',
  deactivated_at timestamptz,
  address text,
  phone text,
  latitude numeric(9, 6),
  longitude numeric(9, 6),
  waitlist_geolocation_enabled boolean not null default false,
  waitlist_radius_meters integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branches_id_organization_key unique (id, organization_id),
  constraint branches_coordinates_pair_check
    check ((latitude is null) = (longitude is null)),
  constraint branches_latitude_check
    check (latitude is null or latitude between -90 and 90),
  constraint branches_longitude_check
    check (longitude is null or longitude between -180 and 180),
  constraint branches_radius_check
    check (waitlist_radius_meters is null or waitlist_radius_meters > 0),
  constraint branches_geolocation_config_check check (
    not waitlist_geolocation_enabled
    or (
      latitude is not null
      and longitude is not null
      and waitlist_radius_meters is not null
    )
  ),
  constraint branches_status_timestamp_check
    check (status <> 'inactive' or deactivated_at is not null)
);

create index branches_organization_status_idx
  on public.branches (organization_id, status);

create trigger branches_validate_timezone
  before insert or update of timezone on public.branches
  for each row execute function private.validate_iana_timezone();

create trigger organizations_set_updated_at
  before update on public.organizations
  for each row execute function private.set_updated_at();

create trigger branches_set_updated_at
  before update on public.branches
  for each row execute function private.set_updated_at();

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique
    references public.organizations (id) on delete restrict,
  plan_code text not null
    references public.plans (code) on delete restrict,
  state public.subscription_state not null default 'active',
  current_period_start timestamptz,
  current_period_end timestamptz,
  grace_period_ends_at timestamptz,
  restricted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subscriptions_id_organization_key unique (id, organization_id),
  constraint subscriptions_period_order_check check (
    current_period_end is null
    or current_period_start is null
    or current_period_end > current_period_start
  ),
  constraint subscriptions_grace_order_check check (
    grace_period_ends_at is null
    or current_period_end is null
    or grace_period_ends_at >= current_period_end
  )
);

create index subscriptions_state_idx
  on public.subscriptions (state);

create trigger subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function private.set_updated_at();

create table public.subscription_events (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null,
  organization_id uuid not null,
  event_type text not null,
  from_plan_code text
    references public.plans (code) on delete restrict,
  to_plan_code text
    references public.plans (code) on delete restrict,
  from_state public.subscription_state,
  to_state public.subscription_state,
  effective_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint subscription_events_subscription_organization_fkey
    foreign key (subscription_id, organization_id)
    references public.subscriptions (id, organization_id)
    on delete restrict
);

create index subscription_events_organization_created_idx
  on public.subscription_events (organization_id, created_at desc);

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'organizations',
    'branches',
    'subscriptions',
    'subscription_events'
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

comment on table public.organizations is
  'Organization tenant root. Soft deletion uses status/deleted_at; no hard delete is part of the initial foundation.';

comment on table public.branches is
  'Branch tenant scope. Composite (id, organization_id) key supports tenant-consistent child foreign keys.';

comment on table public.subscriptions is
  'One subscription per organization. Plan catalog and grace-period values remain pending approval.';

comment on table public.subscription_events is
  'Historical subscription transitions. Not a substitute for audit_events.';
