-- M4.3: Contract-shaped KDS read RPCs.
--
-- Scope:
--   * list_kitchen_tickets: bounded, branch-scoped active or historical board.
--   * get_kitchen_ticket: one complete ticket view.
--
-- The read model returns operational information only. It never returns item
-- prices, subtotals, discounts, order totals, or payment data.
--
-- Authorization mirrors the M4.1/M4.2 kitchen rule: Owner/Admin/Manager and
-- Kitchen Staff in the branch may read; Cashier and anonymous clients are
-- denied. Station access remains branch-wide for the first release.
--
-- Design: docs/m4-kitchen-ticket-lifecycle.md and docs/api-and-rpc-contracts.md.

-- ---------------------------------------------------------------------------
-- 1. Complete KDS ticket JSON
-- ---------------------------------------------------------------------------

create or replace function private.kitchen_ticket_board_json(p_ticket_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ticketId', t.id,
    'organizationId', t.organization_id,
    'branchId', t.branch_id,
    'stationId', t.station_id,
    'stationName', ks.name,
    'generation', t.generation,
    'status', t.status,
    'startedAt', t.started_at,
    'readyAt', t.ready_at,
    'completedAt', t.completed_at,
    'cancelledAt', t.cancelled_at,
    'cancelledByActorType', t.cancelled_by_actor_type,
    'cancelledByStaffId', t.cancelled_by_staff_id,
    'cancellationReason', t.cancellation_reason,
    'createdAt', t.created_at,
    'updatedAt', t.updated_at,
    'order', jsonb_build_object(
      'orderId', o.id,
      'orderReference', o.order_reference,
      'status', o.status,
      'source', o.source,
      'acceptedAt', o.accepted_at,
      'notes', o.notes,
      'tableId', rt.id,
      'tableLabel', rt.label
    ),
    'items', coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'ticketItemId', ti.id,
                   'ticketId', ti.ticket_id,
                   'orderItemId', ti.order_item_id,
                   'menuItemId', oi.menu_item_id,
                   'name', oi.item_name_snapshot,
                   'quantity', oi.quantity,
                   'notes', oi.notes,
                   'status', ti.status,
                   'startedAt', ti.started_at,
                   'readyAt', ti.ready_at,
                   'completedAt', ti.completed_at,
                   'cancelledAt', ti.cancelled_at,
                   'cancelledByActorType', ti.cancelled_by_actor_type,
                   'cancelledByStaffId', ti.cancelled_by_staff_id,
                   'cancellationReason', ti.cancellation_reason,
                   'createdAt', ti.created_at,
                   'updatedAt', ti.updated_at,
                   -- Operational modifier snapshots only; no price deltas.
                   'modifiers', coalesce(
                     (
                       select jsonb_agg(
                                jsonb_build_object(
                                  'modifierGroupId', m.modifier_group_id,
                                  'modifierOptionId', m.modifier_option_id,
                                  'groupName', m.group_name_snapshot,
                                  'optionName', m.option_name_snapshot
                                )
                                order by m.group_name_snapshot,
                                         m.option_name_snapshot,
                                         m.id
                              )
                       from public.order_item_modifiers m
                       where m.order_item_id = ti.order_item_id
                     ),
                     '[]'::jsonb
                   )
                 )
                 order by oi.created_at, ti.id
               )
        from public.kitchen_ticket_items ti
        join public.order_items oi
          on oi.id = ti.order_item_id
         and oi.order_id = ti.order_id
         and oi.branch_id = ti.branch_id
         and oi.organization_id = ti.organization_id
        where ti.ticket_id = t.id
          and ti.organization_id = t.organization_id
          and ti.branch_id = t.branch_id
      ),
      '[]'::jsonb
    )
  )
  from public.kitchen_tickets t
  join public.kitchen_stations ks
    on ks.id = t.station_id
   and ks.branch_id = t.branch_id
   and ks.organization_id = t.organization_id
  join public.orders o
    on o.id = t.order_id
   and o.branch_id = t.branch_id
   and o.organization_id = t.organization_id
  left join public.dining_sessions ds
    on ds.id = o.dining_session_id
   and ds.branch_id = o.branch_id
   and ds.organization_id = o.organization_id
  left join public.restaurant_tables rt
    on rt.id = ds.table_id
   and rt.branch_id = ds.branch_id
   and rt.organization_id = ds.organization_id
  where t.id = p_ticket_id;
$$;

revoke all on function private.kitchen_ticket_board_json(uuid) from public;

comment on function private.kitchen_ticket_board_json(uuid) is
  'Complete operational KDS ticket JSON with station name, order context, table label, item notes, and modifier snapshots. Financial fields are intentionally excluded.';

-- ---------------------------------------------------------------------------
-- 2. List active or historical tickets
-- ---------------------------------------------------------------------------

create or replace function public.list_kitchen_tickets(
  p_branch_id uuid,
  p_station_id uuid default null,
  p_statuses public.kitchen_ticket_status[] default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_statuses public.kitchen_ticket_status[];
  v_history boolean;
  v_tickets jsonb;
  v_has_more boolean;
begin
  perform authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  if not exists (
    select 1
    from public.branches b
    where b.id = p_branch_id
      and b.organization_id = v_org_id
  ) then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  perform authz.assert_branch_role(
    p_branch_id,
    array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
  );

  if p_station_id is not null then
    if not exists (
      select 1
      from public.kitchen_stations ks
      where ks.id = p_station_id
        and ks.organization_id = v_org_id
        and ks.branch_id = p_branch_id
    ) then
      perform private.raise_app_error(
        'KITCHEN_STATION_NOT_FOUND',
        'Kitchen station was not found'
      );
    end if;
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Page size must be between 1 and 100'
    );
  end if;

  if p_offset is null or p_offset < 0 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Offset cannot be negative'
    );
  end if;

  if p_statuses is not null and cardinality(p_statuses) = 0 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'At least one ticket status is required'
    );
  end if;

  v_statuses := coalesce(
    p_statuses,
    array['pending', 'preparing', 'ready']::public.kitchen_ticket_status[]
  );

  v_history := exists (
    select 1
    from unnest(v_statuses) as s(status)
    where s.status in ('completed', 'cancelled')
  );

  -- History is never an unrestricted query. Completed and cancelled tickets
  -- require an explicit, bounded time window; active-board callers may also
  -- narrow the window.
  if v_history then
    if p_from is null or p_to is null then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'History requests require an explicit from/to time window'
      );
    end if;

    if p_from >= p_to then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'The date range start must precede the end'
      );
    end if;

    if p_to - p_from > interval '31 days' then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'The history window cannot exceed 31 days'
      );
    end if;
  elsif p_from is not null and p_to is not null and p_from >= p_to then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'The date range start must precede the end'
    );
  end if;

  with page as (
    select t.id, t.created_at
    from public.kitchen_tickets t
    where t.organization_id = v_org_id
      and t.branch_id = p_branch_id
      and (p_station_id is null or t.station_id = p_station_id)
      and t.status = any (v_statuses)
      and (p_from is null or t.created_at >= p_from)
      and (p_to is null or t.created_at < p_to)
    order by t.created_at asc, t.id asc
    limit p_limit + 1
    offset p_offset
  ),
  numbered as (
    select p.id,
           p.created_at,
           row_number() over (order by p.created_at asc, p.id asc) as rn
    from page p
  )
  select coalesce(
           jsonb_agg(
             private.kitchen_ticket_board_json(n.id)
             order by n.created_at asc, n.id asc
           ) filter (where n.rn <= p_limit),
           '[]'::jsonb
         ),
         (select count(*) from numbered) > p_limit
    into v_tickets, v_has_more
    from numbered n;

  return jsonb_build_object(
    'branchId', p_branch_id,
    'stationId', p_station_id,
    'statuses', v_statuses,
    'from', p_from,
    'to', p_to,
    'tickets', v_tickets,
    'pageSize', p_limit,
    'hasMore', v_has_more,
    'nextOffset', case when v_has_more then p_offset + p_limit else null end
  );
end;
$$;

revoke all on function public.list_kitchen_tickets(
  uuid,
  uuid,
  public.kitchen_ticket_status[],
  integer,
  integer,
  timestamptz,
  timestamptz
) from public;

comment on function public.list_kitchen_tickets(
  uuid,
  uuid,
  public.kitchen_ticket_status[],
  integer,
  integer,
  timestamptz,
  timestamptz
) is
  'Returns a bounded, oldest-first KDS board for an accessible branch. Defaults to pending/preparing/ready; completed and cancelled history requires an explicit from/to window of at most 31 days.';

-- ---------------------------------------------------------------------------
-- 3. Get one ticket
-- ---------------------------------------------------------------------------

create or replace function public.get_kitchen_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_ticket_org_id uuid;
  v_branch_id uuid;
  v_ticket jsonb;
begin
  perform authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select t.organization_id, t.branch_id
    into v_ticket_org_id, v_branch_id
    from public.kitchen_tickets t
   where t.id = p_ticket_id;

  if v_ticket_org_id is null
     or v_ticket_org_id is distinct from v_org_id
  then
    perform private.raise_app_error(
      'KITCHEN_TICKET_NOT_FOUND',
      'Kitchen ticket was not found'
    );
  end if;

  perform authz.assert_branch_role(
    v_branch_id,
    array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
  );

  v_ticket := private.kitchen_ticket_board_json(p_ticket_id);

  if v_ticket is null then
    perform private.raise_app_error(
      'KITCHEN_TICKET_NOT_FOUND',
      'Kitchen ticket was not found'
    );
  end if;

  return v_ticket;
end;
$$;

revoke all on function public.get_kitchen_ticket(uuid) from public;

comment on function public.get_kitchen_ticket(uuid) is
  'Returns one complete operational KDS ticket. Cross-organization access reports KITCHEN_TICKET_NOT_FOUND without revealing existence. Cashier and anonymous clients are denied.';

-- ---------------------------------------------------------------------------
-- 4. Grants
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.list_kitchen_tickets(uuid, uuid, public.kitchen_ticket_status[], integer, integer, timestamptz, timestamptz) to authenticated';
    execute 'grant execute on function public.get_kitchen_ticket(uuid) to authenticated';
  end if;
end
$$;
