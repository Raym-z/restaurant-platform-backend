-- M3 core POS operations: table availability and dining-session RPCs.
--
-- Authorization uses the existing authz helpers only. The role checks below are
-- the single integration boundary that a future branch-scoped role model can
-- adapt without changing these RPC signatures.

create or replace function public.list_branch_tables(
  p_branch_id uuid,
  p_include_inactive boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_org_id uuid;
  v_tables jsonb;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id
    into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null or v_branch_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_branch_access(p_branch_id);

  select coalesce(
           jsonb_agg(
             private.table_summary_json(rt.id)
             order by rt.label, rt.id
           ),
           '[]'::jsonb
         )
    into v_tables
    from public.restaurant_tables rt
   where rt.organization_id = v_org_id
     and rt.branch_id = p_branch_id
     and (p_include_inactive or rt.status = 'active');

  return jsonb_build_object(
    'branchId', p_branch_id,
    'tables', v_tables
  );
end;
$$;

create or replace function public.get_table(p_table_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_table_org_id uuid;
  v_branch_id uuid;
  v_table jsonb;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_branch_access(v_branch_id);

  v_table := private.table_summary_json(p_table_id);

  if v_table is null then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  return v_table;
end;
$$;

create or replace function public.get_table_availability(p_table_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_table_org_id uuid;
  v_branch_id uuid;
  v_table jsonb;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_branch_access(v_branch_id);

  v_table := private.table_summary_json(p_table_id);

  if v_table is null then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  return jsonb_build_object(
    'tableId', v_table -> 'tableId',
    'organizationId', v_table -> 'organizationId',
    'branchId', v_table -> 'branchId',
    'status', v_table -> 'status',
    'availability', v_table -> 'availability',
    'activeSessionId', v_table -> 'activeSessionId',
    'activeSessionOpenedAt', v_table -> 'activeSessionOpenedAt'
  );
end;
$$;

create or replace function public.get_active_dining_session(p_table_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_table_org_id uuid;
  v_branch_id uuid;
  v_session_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_branch_access(v_branch_id);

  select ds.id
    into v_session_id
    from public.dining_sessions ds
   where ds.table_id = p_table_id
     and ds.status = 'active';

  return jsonb_build_object(
    'tableId', p_table_id,
    'activeSession',
    case
      when v_session_id is null then null
      else private.dining_session_detail_json(v_session_id)
    end
  );
end;
$$;

create or replace function public.list_branch_dining_sessions(
  p_branch_id uuid,
  p_status public.dining_session_status default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_org_id uuid;
  v_sessions jsonb;
  v_has_more boolean;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id
    into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null or v_branch_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_branch_access(p_branch_id);

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Page size must be between 1 and 100');
  end if;

  if p_offset is null or p_offset < 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Offset cannot be negative');
  end if;

  if p_from is not null and p_to is not null and p_from >= p_to then
    perform private.raise_app_error('VALIDATION_ERROR', 'The date range start must precede the end');
  end if;

  with page as (
    select ds.id, ds.opened_at
    from public.dining_sessions ds
    where ds.organization_id = v_org_id
      and ds.branch_id = p_branch_id
      and (p_status is null or ds.status = p_status)
      and (p_from is null or ds.opened_at >= p_from)
      and (p_to is null or ds.opened_at < p_to)
    order by ds.opened_at desc, ds.id desc
    limit p_limit + 1
    offset p_offset
  ),
  numbered as (
    select p.id,
           p.opened_at,
           row_number() over (order by p.opened_at desc, p.id desc) as rn
    from page p
  )
  select coalesce(
           jsonb_agg(
             private.dining_session_summary_json(n.id)
             order by n.opened_at desc, n.id desc
           ) filter (where n.rn <= p_limit),
           '[]'::jsonb
         ),
         (select count(*) from numbered) > p_limit
    into v_sessions, v_has_more
    from numbered n;

  return jsonb_build_object(
    'branchId', p_branch_id,
    'sessions', v_sessions,
    'pageSize', p_limit,
    'hasMore', v_has_more,
    'nextOffset', case when v_has_more then p_offset + p_limit else null end
  );
end;
$$;

create or replace function public.open_dining_session(
  p_table_id uuid,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_table_org_id uuid;
  v_branch_id uuid;
  v_table_status text;
  v_session_id uuid;
  v_existing_session_id uuid;
  v_idem jsonb;
  v_response jsonb;
  v_fingerprint text;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  perform authz.assert_branch_role(
    v_branch_id,
    array['owner', 'admin', 'manager', 'cashier']::text[]
  );

  v_fingerprint := private.sha256_hex(
    concat_ws('|', 'dining_session.open', p_table_id::text)
  );

  if p_idempotency_key is not null then
    v_idem := private.idempotency_begin(
      'staff',
      v_actor_staff_id,
      'dining_session.open',
      p_idempotency_key,
      'staff',
      v_actor_staff_id,
      v_fingerprint,
      now() + interval '24 hours'
    );

    if v_idem ->> 'status' = 'replay' then
      return v_idem -> 'response';
    end if;
  end if;

  perform authz.assert_org_operational(v_org_id);

  -- Lock order: organization advisory (above), branch, table, session.
  perform 1
    from public.branches b
   where b.id = v_branch_id
   for update;

  select rt.status::text, rt.organization_id, rt.branch_id
    into v_table_status, v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id
   for update;

  if v_table_org_id is null or v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  if not exists (
    select 1
    from public.branches b
    where b.id = v_branch_id
      and b.organization_id = v_org_id
      and b.status = 'active'
  ) then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_table_status <> 'active' then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'An inactive table cannot open a new dining session'
    );
  end if;

  select ds.id
    into v_existing_session_id
    from public.dining_sessions ds
   where ds.table_id = p_table_id
     and ds.status = 'active'
   for update;

  if v_existing_session_id is not null then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'The table already has an active dining session'
    );
  end if;

  insert into public.dining_sessions (
    organization_id,
    branch_id,
    table_id,
    opened_by_staff_id
  )
  values (
    v_org_id,
    v_branch_id,
    p_table_id,
    v_actor_staff_id
  )
  returning id into v_session_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'dining_session.opened', 'dining_session', v_session_id, null,
    jsonb_build_object('table_id', p_table_id)
  );

  v_response := private.dining_session_detail_json(v_session_id);

  if p_idempotency_key is not null then
    perform private.idempotency_complete((v_idem ->> 'id')::uuid, v_response);
  end if;

  return v_response;
end;
$$;

create or replace function public.get_dining_session(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_session_org_id uuid;
  v_branch_id uuid;
  v_session jsonb;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select ds.organization_id, ds.branch_id
    into v_session_org_id, v_branch_id
    from public.dining_sessions ds
   where ds.id = p_session_id;

  if v_session_org_id is null or v_session_org_id is distinct from v_org_id then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  perform authz.assert_branch_access(v_branch_id);

  v_session := private.dining_session_detail_json(p_session_id);

  if v_session is null then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  return v_session;
end;
$$;

create or replace function public.close_dining_session(
  p_session_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_session_org_id uuid;
  v_branch_id uuid;
  v_table_id uuid;
  v_session_status text;
  v_revoked_token_count integer;
  v_response jsonb;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select ds.organization_id, ds.branch_id, ds.table_id, ds.status::text
    into v_session_org_id, v_branch_id, v_table_id, v_session_status
    from public.dining_sessions ds
   where ds.id = p_session_id;

  if v_session_org_id is null or v_session_org_id is distinct from v_org_id then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  perform authz.assert_branch_role(
    v_branch_id,
    array['owner', 'admin', 'manager', 'cashier']::text[]
  );

  if p_reason is not null and length(btrim(p_reason)) > 500 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Close reason cannot exceed 500 characters');
  end if;

  -- Closing existing sessions remains available during a restricted
  -- subscription or suspension; only new operational work is blocked.
  perform authz.acquire_org_shared_lock(v_org_id);

  perform 1
    from public.restaurant_tables rt
   where rt.id = v_table_id
   for update;

  select ds.status::text
    into v_session_status
    from public.dining_sessions ds
   where ds.id = p_session_id
   for update;

  if v_session_status is null then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  if v_session_status = 'closed' then
    perform private.raise_app_error('SESSION_ALREADY_CLOSED', 'The dining session is already closed');
  end if;

  if exists (
    select 1
    from public.orders o
    where o.dining_session_id = p_session_id
      and o.status not in ('completed', 'cancelled')
  ) then
    perform private.raise_app_error(
      'SESSION_BALANCE_OUTSTANDING',
      'All orders must be completed or cancelled before the dining session can close'
    );
  end if;

  update public.dining_sessions
     set status = 'closed',
         closed_at = now(),
         closed_by_staff_id = v_actor_staff_id
   where id = p_session_id;

  update private.guest_tokens
     set revoked_at = now()
   where dining_session_id = p_session_id
     and revoked_at is null;

  get diagnostics v_revoked_token_count = row_count;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'dining_session.closed', 'dining_session', p_session_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('revoked_guest_token_count', v_revoked_token_count)
  );

  v_response := private.dining_session_detail_json(p_session_id);
  return v_response;
end;
$$;

revoke all on function public.list_branch_tables(uuid, boolean) from public;
revoke all on function public.get_table(uuid) from public;
revoke all on function public.get_table_availability(uuid) from public;
revoke all on function public.get_active_dining_session(uuid) from public;
revoke all on function public.list_branch_dining_sessions(
  uuid, public.dining_session_status, timestamptz, timestamptz, integer, integer
) from public;
revoke all on function public.open_dining_session(uuid, text) from public;
revoke all on function public.get_dining_session(uuid) from public;
revoke all on function public.close_dining_session(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.list_branch_tables(uuid, boolean) to authenticated';
    execute 'grant execute on function public.get_table(uuid) to authenticated';
    execute 'grant execute on function public.get_table_availability(uuid) to authenticated';
    execute 'grant execute on function public.get_active_dining_session(uuid) to authenticated';
    execute 'grant execute on function public.list_branch_dining_sessions(uuid, public.dining_session_status, timestamptz, timestamptz, integer, integer) to authenticated';
    execute 'grant execute on function public.open_dining_session(uuid, text) to authenticated';
    execute 'grant execute on function public.get_dining_session(uuid) to authenticated';
    execute 'grant execute on function public.close_dining_session(uuid, text) to authenticated';
  end if;
end
$$;

comment on function public.list_branch_tables(uuid, boolean) is
  'Lists branch-scoped tables with current availability. Requires active staff branch access.';

comment on function public.open_dining_session(uuid, text) is
  'Opens one active dining session for an active, available table. Idempotent when a key is supplied.';

comment on function public.close_dining_session(uuid, text) is
  'Closes an active session only when every order is completed or cancelled; revokes guest tokens.';
