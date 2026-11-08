-- Tables, permanent QR identifiers, dining sessions, and private guest tokens.

create table public.restaurant_tables (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  label text not null,
  capacity smallint not null,
  status public.table_status not null default 'active',
  deactivated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint restaurant_tables_capacity_check check (capacity > 0),
  constraint restaurant_tables_status_timestamp_check
    check (status <> 'inactive' or deactivated_at is not null),
  constraint restaurant_tables_id_branch_organization_key
    unique (id, branch_id, organization_id),
  constraint restaurant_tables_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict
);

create index restaurant_tables_branch_status_idx
  on public.restaurant_tables (branch_id, status);

create trigger restaurant_tables_set_updated_at
  before update on public.restaurant_tables
  for each row execute function private.set_updated_at();

create table public.table_qr_identifiers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  table_id uuid not null,
  public_id uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint table_qr_identifiers_table_branch_organization_fkey
    foreign key (table_id, branch_id, organization_id)
    references public.restaurant_tables (id, branch_id, organization_id)
    on delete restrict
);

create unique index table_qr_identifiers_one_active_per_table
  on public.table_qr_identifiers (table_id)
  where revoked_at is null;

create table public.dining_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  table_id uuid not null,
  status public.dining_session_status not null default 'active',
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  opened_by_staff_id uuid,
  closed_by_staff_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dining_sessions_status_timestamp_check check (
    (status = 'active' and closed_at is null)
    or (status = 'closed' and closed_at is not null)
  ),
  constraint dining_sessions_id_branch_organization_key
    unique (id, branch_id, organization_id),
  constraint dining_sessions_table_branch_organization_fkey
    foreign key (table_id, branch_id, organization_id)
    references public.restaurant_tables (id, branch_id, organization_id)
    on delete restrict,
  constraint dining_sessions_opened_by_organization_fkey
    foreign key (opened_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint dining_sessions_closed_by_organization_fkey
    foreign key (closed_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create unique index dining_sessions_one_active_per_table
  on public.dining_sessions (table_id)
  where status = 'active';

create index dining_sessions_branch_status_opened_idx
  on public.dining_sessions (branch_id, status, opened_at desc);

create trigger dining_sessions_set_updated_at
  before update on public.dining_sessions
  for each row execute function private.set_updated_at();

create table private.guest_tokens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  dining_session_id uuid not null,
  token_hash bytea not null unique,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_used_at timestamptz,
  device_label text,
  created_at timestamptz not null default now(),
  constraint guest_tokens_expiry_check check (expires_at > issued_at),
  constraint guest_tokens_session_branch_organization_fkey
    foreign key (dining_session_id, branch_id, organization_id)
    references public.dining_sessions (id, branch_id, organization_id)
    on delete restrict
);

create index guest_tokens_active_session_idx
  on private.guest_tokens (dining_session_id)
  where revoked_at is null;

create index guest_tokens_expires_at_idx
  on private.guest_tokens (expires_at);

alter table private.guest_tokens enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert, update, delete on private.guest_tokens to service_role';
  end if;
end
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'restaurant_tables',
    'table_qr_identifiers',
    'dining_sessions'
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

comment on table public.table_qr_identifiers is
  'Permanent table locators. public_id is not a secret or session credential. Regeneration revokes the old identifier.';

comment on table public.dining_sessions is
  'One active session per table is enforced by partial unique index. Session creation remains an Agent 2 transactional operation.';

comment on table private.guest_tokens is
  'Hashed guest tokens only. Token rows may be cleaned up after retention; historical orders reference dining_sessions, not tokens.';

comment on column private.guest_tokens.token_hash is
  'Raw tokens must never be stored. Hash algorithm and token expiry/rotation policy remain Agent 2 decisions.';
