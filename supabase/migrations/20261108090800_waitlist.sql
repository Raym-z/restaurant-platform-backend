-- Branch-scoped waitlist entries.

create table public.waitlist_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  customer_id uuid
    references public.customer_profiles (id) on delete restrict,
  contact_name text,
  contact_phone text,
  party_size smallint not null,
  status public.waitlist_status not null default 'waiting',
  queue_position numeric(20, 10),
  joined_at timestamptz not null default now(),
  notified_at timestamptz,
  seated_at timestamptz,
  cancelled_at timestamptz,
  no_show_at timestamptz,
  cancellation_reason text,
  location_check_passed boolean,
  location_checked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint waitlist_entries_party_size_check check (party_size > 0),
  constraint waitlist_entries_contact_check
    check (customer_id is not null or contact_phone is not null),
  constraint waitlist_entries_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict
);

create unique index waitlist_entries_one_active_per_customer_branch
  on public.waitlist_entries (branch_id, customer_id)
  where status in ('waiting', 'notified') and customer_id is not null;

create unique index waitlist_entries_active_position_unique
  on public.waitlist_entries (branch_id, queue_position)
  where status in ('waiting', 'notified') and queue_position is not null;

create index waitlist_entries_branch_status_position_idx
  on public.waitlist_entries (branch_id, status, queue_position);

create index waitlist_entries_customer_status_idx
  on public.waitlist_entries (customer_id, status);

create trigger waitlist_entries_set_updated_at
  before update on public.waitlist_entries
  for each row execute function private.set_updated_at();

alter table public.waitlist_entries enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.waitlist_entries from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.waitlist_entries from authenticated';
  end if;
end
$$;

comment on table public.waitlist_entries is
  'One active entry per customer per branch is enforced. Queue ordering/reorder algorithm, priority semantics, and no-show thresholds remain Agent 2 decisions.';

comment on column public.waitlist_entries.queue_position is
  'Nullable numeric position with gaps to support audited manual reorder. Agent 2 manages assignment and rebalancing.';

comment on column public.waitlist_entries.location_check_passed is
  'Stores only the geolocation check result. Raw coordinates are not retained.';
