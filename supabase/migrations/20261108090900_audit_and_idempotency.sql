-- Central audit events and scoped idempotency storage.

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_type public.audit_actor_type not null,
  actor_id uuid,
  actor_label text,
  organization_id uuid
    references public.organizations (id) on delete restrict,
  branch_id uuid,
  action text not null,
  target_type text not null,
  target_id uuid,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_events_branch_requires_organization_check
    check (branch_id is null or organization_id is not null),
  constraint audit_events_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches (id, organization_id)
    on delete restrict
);

create index audit_events_organization_created_idx
  on public.audit_events (organization_id, created_at desc);

create index audit_events_branch_created_idx
  on public.audit_events (branch_id, created_at desc);

create index audit_events_target_idx
  on public.audit_events (target_type, target_id);

create index audit_events_actor_idx
  on public.audit_events (actor_id);

create trigger audit_events_prevent_update_delete
  before update or delete on public.audit_events
  for each row execute function private.prevent_audit_mutation();

create trigger audit_events_prevent_truncate
  before truncate on public.audit_events
  for each statement execute function private.prevent_audit_truncate();

alter table public.audit_events enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.audit_events from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.audit_events from authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert on public.audit_events to service_role';
  end if;
end
$$;

create table private.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  scope_type public.idempotency_scope not null,
  scope_id uuid not null,
  operation text not null,
  idempotency_key text not null,
  actor_type public.audit_actor_type not null,
  actor_id uuid,
  request_fingerprint text not null,
  status public.idempotency_status not null default 'pending',
  response_payload jsonb,
  error_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  expires_at timestamptz,
  constraint idempotency_keys_scoped_unique
    unique (scope_type, scope_id, operation, idempotency_key)
);

create index idempotency_keys_scope_lookup_idx
  on private.idempotency_keys (scope_type, scope_id, operation);

create index idempotency_keys_expires_at_idx
  on private.idempotency_keys (expires_at);

alter table private.idempotency_keys enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert, update, delete on private.idempotency_keys to service_role';
  end if;
end
$$;

comment on table public.audit_events is
  'Central audit history. INSERT is allowed for trusted backend operations; UPDATE, DELETE, and TRUNCATE are blocked. Agent 2 owns audit write paths and read policies.';

comment on table private.idempotency_keys is
  'Scoped idempotency storage. Uniqueness is (scope_type, scope_id, operation, idempotency_key), not a global key. Agent 2 derives scope_id server-side and owns semantics/retention.';

comment on column private.idempotency_keys.scope_type is
  'Supported scopes: auth_user, organization, staff, customer, guest_session, platform_admin.';

comment on column private.idempotency_keys.expires_at is
  'Retention/cleanup policy remains an Agent 2 decision; null means no scheduled expiry.';
