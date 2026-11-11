-- M4.2 corrections: ticket identity, aggregate guards, cancellation attribution,
-- completed-item protection, and routing visibility.
--
-- This migration is additive to 20261109160000_m4_kitchen_ticket_lifecycle.sql.
-- It preserves cancelled tickets and audit history while allowing new work to
-- receive a fresh ticket after an earlier ticket for the same order/station has
-- been cancelled.

-- ---------------------------------------------------------------------------
-- 1. Ticket identity and cancellation actor representation
-- ---------------------------------------------------------------------------

alter table public.kitchen_tickets
  add column if not exists generation integer not null default 1,
  add column if not exists cancelled_by_actor_type public.audit_actor_type
    not null default 'staff';

alter table public.kitchen_ticket_items
  add column if not exists cancelled_by_actor_type public.audit_actor_type
    not null default 'staff';

alter table public.kitchen_tickets
  drop constraint if exists kitchen_tickets_order_station_unique,
  drop constraint if exists kitchen_tickets_cancellation_check;

alter table public.kitchen_ticket_items
  drop constraint if exists kitchen_ticket_items_cancellation_check;

alter table public.kitchen_tickets
  add constraint kitchen_tickets_generation_check
    check (generation >= 1),
  add constraint kitchen_tickets_order_station_generation_unique
    unique (order_id, station_id, generation),
  add constraint kitchen_tickets_cancellation_check check (
    status <> 'cancelled'
    or (
      cancelled_at is not null
      and nullif(btrim(cancellation_reason), '') is not null
      and (
        (
          cancelled_by_actor_type = 'staff'
          and cancelled_by_staff_id is not null
        )
        or (
          cancelled_by_actor_type = 'system'
          and cancelled_by_staff_id is null
        )
      )
    )
  );

alter table public.kitchen_ticket_items
  add constraint kitchen_ticket_items_cancellation_check check (
    status <> 'cancelled'
    or (
      cancelled_at is not null
      and nullif(btrim(cancellation_reason), '') is not null
      and (
        (
          cancelled_by_actor_type = 'staff'
          and cancelled_by_staff_id is not null
        )
        or (
          cancelled_by_actor_type = 'system'
          and cancelled_by_staff_id is null
        )
      )
    )
  );

-- At most one active ticket per (order, station). Historical cancelled tickets
-- retain their own generation identity.
create unique index if not exists kitchen_tickets_active_order_station_unique
  on public.kitchen_tickets (order_id, station_id)
  where status <> 'cancelled';

comment on column public.kitchen_tickets.generation is
  'Monotonic per-(order, station) ticket generation. Cancelled tickets keep their generation so new routed work can receive a fresh non-cancelled ticket.';

comment on column public.kitchen_tickets.cancelled_by_actor_type is
  'Cancellation actor domain: staff requires cancelled_by_staff_id; system requires a null staff id.';

comment on column public.kitchen_ticket_items.cancelled_by_actor_type is
  'Cancellation actor domain: staff requires cancelled_by_staff_id; system requires a null staff id.';

comment on table public.kitchen_tickets is
  'Kitchen tickets are one active ticket per (order, station), with historical cancelled generations preserved. The partial unique (order_id, station_id) index protects active work; (order_id, station_id, generation) anchors idempotent generation.';

-- ---------------------------------------------------------------------------
-- 2. Read helpers include generation and cancellation actor information
-- ---------------------------------------------------------------------------

create or replace function private.kitchen_ticket_item_json(p_ticket_item_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ticketItemId', ti.id,
    'ticketId', ti.ticket_id,
    'orderId', ti.order_id,
    'orderItemId', ti.order_item_id,
    'organizationId', ti.organization_id,
    'branchId', ti.branch_id,
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
    'updatedAt', ti.updated_at
  )
  from public.kitchen_ticket_items ti
  join public.order_items oi on oi.id = ti.order_item_id
  where ti.id = p_ticket_item_id;
$$;

revoke all on function private.kitchen_ticket_item_json(uuid) from public;

create or replace function private.kitchen_ticket_json(p_ticket_id uuid)
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
    'orderId', t.order_id,
    'stationId', t.station_id,
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
    'items', coalesce(
      (
        select jsonb_agg(
                 private.kitchen_ticket_item_json(ti.id)
                 order by oi.created_at, ti.id
               )
        from public.kitchen_ticket_items ti
        join public.order_items oi on oi.id = ti.order_item_id
        where ti.ticket_id = t.id
      ),
      '[]'::jsonb
    )
  )
  from public.kitchen_tickets t
  where t.id = p_ticket_id;
$$;

revoke all on function private.kitchen_ticket_json(uuid) from public;

-- ---------------------------------------------------------------------------
-- 3. Exact lifecycle guards
-- ---------------------------------------------------------------------------

create or replace function private.guard_kitchen_ticket_item_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allow_completed_cancel boolean :=
    coalesce(
      current_setting(
        'restaurant_platform.kitchen_allow_completed_cancel',
        true
      ),
      'off'
    ) = 'on';
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status = 'cancelled' then
    perform private.raise_app_error(
      'KITCHEN_INVALID_TRANSITION',
      'A cancelled kitchen ticket item is terminal'
    );
  end if;

  if new.status = 'cancelled' then
    if old.status = 'completed' and not v_allow_completed_cancel then
      perform private.raise_app_error(
        'ORDER_MODIFICATION_NOT_ALLOWED',
        'Completed kitchen work cannot be cancelled or removed'
      );
    end if;

    new.cancelled_at := coalesce(new.cancelled_at, now());

    if nullif(btrim(new.cancellation_reason), '') is null then
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'Cancellation requires a non-empty reason'
      );
    end if;

    if new.cancelled_by_actor_type = 'staff' then
      if new.cancelled_by_staff_id is null then
        perform private.raise_app_error(
          'KITCHEN_CANCELLATION_INVALID',
          'Staff cancellation requires a staff actor'
        );
      end if;
    elsif new.cancelled_by_actor_type = 'system' then
      if new.cancelled_by_staff_id is not null then
        perform private.raise_app_error(
          'KITCHEN_CANCELLATION_INVALID',
          'System cancellation cannot record a staff actor'
        );
      end if;
    else
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'Cancellation actor type must be staff or system'
      );
    end if;

    return new;
  end if;

  if not (
    (old.status = 'pending' and new.status = 'preparing')
    or (old.status = 'preparing' and new.status = 'ready')
    or (old.status = 'ready' and new.status = 'completed')
  ) then
    perform private.raise_app_error(
      'KITCHEN_INVALID_TRANSITION',
      'The requested kitchen ticket item transition is not permitted'
    );
  end if;

  if new.status = 'preparing' then
    new.started_at := coalesce(new.started_at, now());
  elsif new.status = 'ready' then
    new.ready_at := coalesce(new.ready_at, now());
  elsif new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  end if;

  return new;
end;
$$;

revoke all on function private.guard_kitchen_ticket_item_status() from public;

comment on function private.guard_kitchen_ticket_item_status() is
  'Enforces pending -> preparing -> ready -> completed and terminal cancellation. Completed items can only be cancelled by the whole-order cancellation path, never by item removal.';

create or replace function private.guard_kitchen_ticket_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
  v_active integer;
  v_pending integer;
  v_preparing integer;
  v_ready integer;
  v_completed integer;
  v_expected public.kitchen_ticket_status;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status = 'cancelled' then
    perform private.raise_app_error(
      'KITCHEN_INVALID_TRANSITION',
      'A cancelled kitchen ticket is terminal'
    );
  end if;

  select count(*),
         count(*) filter (where status <> 'cancelled'),
         count(*) filter (where status = 'pending'),
         count(*) filter (where status = 'preparing'),
         count(*) filter (where status = 'ready'),
         count(*) filter (where status = 'completed')
    into v_total, v_active, v_pending, v_preparing, v_ready, v_completed
    from public.kitchen_ticket_items
   where ticket_id = new.id;

  if new.status = 'cancelled' then
    if v_active > 0 then
      perform private.raise_app_error(
        'KITCHEN_TICKET_INCONSISTENT',
        'A kitchen ticket with active items cannot be cancelled directly'
      );
    end if;

    new.cancelled_at := coalesce(new.cancelled_at, now());

    if nullif(btrim(new.cancellation_reason), '') is null then
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'Cancellation requires a non-empty reason'
      );
    end if;

    if new.cancelled_by_actor_type = 'staff' then
      if new.cancelled_by_staff_id is null then
        perform private.raise_app_error(
          'KITCHEN_CANCELLATION_INVALID',
          'Staff cancellation requires a staff actor'
        );
      end if;
    elsif new.cancelled_by_actor_type = 'system' then
      if new.cancelled_by_staff_id is not null then
        perform private.raise_app_error(
          'KITCHEN_CANCELLATION_INVALID',
          'System cancellation cannot record a staff actor'
        );
      end if;
    else
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'Cancellation actor type must be staff or system'
      );
    end if;

    return new;
  end if;

  -- Empty tickets are explicitly non-aggregatable. They may still be cancelled
  -- with attribution, but cannot be assigned a non-cancelled aggregate state.
  if v_total = 0 then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'An empty kitchen ticket has no aggregate status'
    );
  end if;

  if v_active = 0 then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'A kitchen ticket whose items are all cancelled must be cancelled'
    );
  end if;

  if v_completed = v_active then
    v_expected := 'completed';
  elsif v_ready + v_completed = v_active then
    v_expected := 'ready';
  elsif v_preparing + v_ready + v_completed > 0 then
    v_expected := 'preparing';
  else
    v_expected := 'pending';
  end if;

  if new.status is distinct from v_expected then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      format(
        'Kitchen ticket status %s does not match the item aggregate %s',
        new.status,
        v_expected
      )
    );
  end if;

  if new.status = 'preparing' then
    new.started_at := coalesce(new.started_at, now());
  elsif new.status = 'ready' then
    new.ready_at := coalesce(new.ready_at, now());
  elsif new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  end if;

  return new;
end;
$$;

revoke all on function private.guard_kitchen_ticket_status() from public;

comment on function private.guard_kitchen_ticket_status() is
  'Rejects persisted ticket statuses that do not exactly match the active-item aggregate. Direct cancellation requires all items to be cancelled first. Empty tickets cannot receive a non-cancelled aggregate.';

-- ---------------------------------------------------------------------------
-- 4. Ticket aggregation
-- ---------------------------------------------------------------------------

create or replace function private.recalculate_kitchen_ticket_status(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket public.kitchen_tickets%rowtype;
  v_total integer;
  v_active integer;
  v_pending integer;
  v_preparing integer;
  v_ready integer;
  v_completed integer;
  v_new_status public.kitchen_ticket_status;
  v_actor uuid;
  v_actor_type public.audit_actor_type;
  v_reason text;
begin
  select *
    into v_ticket
    from public.kitchen_tickets t
   where t.id = p_ticket_id
   for update;

  if not found then
    return;
  end if;

  -- Cancelled is terminal. Aggregation never turns a cancelled ticket into a
  -- completed ticket or reopens it.
  if v_ticket.status = 'cancelled' then
    return;
  end if;

  select count(*),
         count(*) filter (where status <> 'cancelled'),
         count(*) filter (where status = 'pending'),
         count(*) filter (where status = 'preparing'),
         count(*) filter (where status = 'ready'),
         count(*) filter (where status = 'completed')
    into v_total, v_active, v_pending, v_preparing, v_ready, v_completed
    from public.kitchen_ticket_items ti
   where ti.ticket_id = p_ticket_id;

  -- Empty tickets are left untouched rather than guessed at.
  if v_total = 0 then
    return;
  end if;

  if v_active = 0 then
    select ti.cancelled_by_staff_id, ti.cancelled_by_actor_type,
           ti.cancellation_reason
      into v_actor, v_actor_type, v_reason
      from public.kitchen_ticket_items ti
     where ti.ticket_id = p_ticket_id
       and ti.status = 'cancelled'
     order by ti.cancelled_at desc nulls last, ti.id
     limit 1;

    v_reason := coalesce(
      nullif(btrim(v_reason), ''),
      'All kitchen ticket items were cancelled'
    );

    if v_actor_type is null then
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'A cancellation actor type is required when all kitchen ticket items are cancelled'
      );
    end if;

    update public.kitchen_tickets
       set status = 'cancelled',
           cancelled_at = coalesce(cancelled_at, now()),
           cancelled_by_actor_type = v_actor_type,
           cancelled_by_staff_id = v_actor,
           cancellation_reason = coalesce(cancellation_reason, v_reason)
     where id = p_ticket_id;

    return;
  end if;

  if v_completed = v_active then
    v_new_status := 'completed';
  elsif v_ready + v_completed = v_active then
    v_new_status := 'ready';
  elsif v_preparing + v_ready + v_completed > 0 then
    v_new_status := 'preparing';
  else
    v_new_status := 'pending';
  end if;

  if v_new_status is distinct from v_ticket.status then
    update public.kitchen_tickets
       set status = v_new_status,
           started_at = case
             when v_new_status in ('preparing', 'ready', 'completed')
               then coalesce(started_at, now())
             else started_at
           end,
           ready_at = case
             when v_new_status in ('ready', 'completed')
               then coalesce(ready_at, now())
             else ready_at
           end,
           completed_at = case
             when v_new_status = 'completed'
               then coalesce(completed_at, now())
             else completed_at
           end
     where id = p_ticket_id;
  end if;
end;
$$;

revoke all on function private.recalculate_kitchen_ticket_status(uuid) from public;

comment on function private.recalculate_kitchen_ticket_status(uuid) is
  'Derives kitchen ticket status from active ticket items. Cancelled tickets are terminal; empty tickets are left unchanged; full cancellation copies the latest item cancellation actor and reason.';

-- ---------------------------------------------------------------------------
-- 5. Idempotent ticket generation with fresh generations after cancellation
-- ---------------------------------------------------------------------------

create or replace function private.generate_kitchen_tickets(
  p_order_id uuid,
  p_order_item_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_route record;
  v_ticket_id uuid;
  v_generation integer;
  v_inserted integer;
  v_created integer := 0;
  v_ticket_ids uuid[] := '{}';
begin
  -- Serialize generation for the order. The M3 add/remove/transition RPCs also
  -- lock the order first, so ticket identity changes cannot race item edits.
  select *
    into v_order
    from public.orders o
   where o.id = p_order_id
   for update;

  if not found then
    perform private.raise_app_error('ORDER_NOT_FOUND', 'Order was not found');
  end if;

  -- Tickets are generated at acceptance. Pending orders remain ticket-free.
  if v_order.status <> 'accepted' then
    return 0;
  end if;

  for v_route in
    with item_level_items as (
      select distinct oi.id as order_item_id
        from public.order_items oi
        join public.kitchen_station_menu_items r
          on r.menu_item_id = oi.menu_item_id
         and r.organization_id = oi.organization_id
         and r.branch_id = oi.branch_id
       where oi.order_id = p_order_id
         and oi.status <> 'cancelled'
         and (p_order_item_id is null or oi.id = p_order_item_id)
    ),
    resolved as (
      -- Item-level routing wins whenever any item-level route is configured.
      select oi.id as order_item_id, ks.id as station_id
        from public.order_items oi
        join public.kitchen_station_menu_items r
          on r.menu_item_id = oi.menu_item_id
         and r.organization_id = oi.organization_id
         and r.branch_id = oi.branch_id
        join public.kitchen_stations ks
          on ks.id = r.station_id
         and ks.organization_id = oi.organization_id
         and ks.branch_id = oi.branch_id
         and ks.status = 'active'
       where oi.order_id = p_order_id
         and oi.status <> 'cancelled'
         and (p_order_item_id is null or oi.id = p_order_item_id)
      union
      -- Category routing is a fallback only for items with no item-level route.
      select oi.id as order_item_id, ks.id as station_id
        from public.order_items oi
        join public.menu_items mi on mi.id = oi.menu_item_id
        join public.kitchen_station_menu_categories r
          on r.menu_category_id = mi.category_id
         and r.organization_id = oi.organization_id
         and r.branch_id = oi.branch_id
        join public.kitchen_stations ks
          on ks.id = r.station_id
         and ks.organization_id = oi.organization_id
         and ks.branch_id = oi.branch_id
         and ks.status = 'active'
       where oi.order_id = p_order_id
         and oi.status <> 'cancelled'
         and (p_order_item_id is null or oi.id = p_order_item_id)
         and oi.id not in (select ili.order_item_id from item_level_items ili)
    )
    select r.order_item_id, r.station_id
      from resolved r
     order by r.station_id, r.order_item_id
  loop
    v_ticket_id := null;
    v_generation := null;
    v_inserted := 0;

    -- Reuse the current active ticket for this order/station, regardless of
    -- how many historical generations exist.
    select t.id
      into v_ticket_id
      from public.kitchen_tickets t
     where t.order_id = p_order_id
       and t.station_id = v_route.station_id
       and t.status <> 'cancelled'
     order by t.generation desc
     limit 1
     for update;

    if v_ticket_id is null then
      select coalesce(max(t.generation), 0) + 1
        into v_generation
        from public.kitchen_tickets t
       where t.order_id = p_order_id
         and t.station_id = v_route.station_id;

      insert into public.kitchen_tickets (
        organization_id,
        branch_id,
        order_id,
        station_id,
        generation,
        status
      )
      values (
        v_order.organization_id,
        v_order.branch_id,
        p_order_id,
        v_route.station_id,
        v_generation,
        'pending'
      )
      on conflict (order_id, station_id, generation) do nothing
      returning id into v_ticket_id;

      get diagnostics v_inserted = row_count;

      if v_ticket_id is null then
        select t.id
          into v_ticket_id
          from public.kitchen_tickets t
         where t.order_id = p_order_id
           and t.station_id = v_route.station_id
           and t.generation = v_generation
           and t.status <> 'cancelled';
      end if;
    end if;

    -- Defensive: never create ticket items without a valid active ticket.
    if v_ticket_id is null then
      continue;
    end if;

    if v_inserted = 1 then
      v_created := v_created + 1;
    end if;

    insert into public.kitchen_ticket_items (
      organization_id,
      branch_id,
      ticket_id,
      order_id,
      order_item_id,
      status
    )
    values (
      v_order.organization_id,
      v_order.branch_id,
      v_ticket_id,
      p_order_id,
      v_route.order_item_id,
      'pending'
    )
    on conflict (ticket_id, order_item_id) do nothing;

    if not (v_ticket_id = any (v_ticket_ids)) then
      v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);
    end if;
  end loop;

  foreach v_ticket_id in array v_ticket_ids
  loop
    perform private.recalculate_kitchen_ticket_status(v_ticket_id);
  end loop;

  return v_created;
end;
$$;

revoke all on function private.generate_kitchen_tickets(uuid, uuid) from public;

comment on function private.generate_kitchen_tickets(uuid, uuid) is
  'Idempotently resolves active station routing and reuses the active ticket, or creates the next generation after cancellation. Item-level routing overrides category routing. Unrouted items are skipped.';

-- ---------------------------------------------------------------------------
-- 6. Cancellation propagation with explicit actor domains
-- ---------------------------------------------------------------------------

create or replace function private.cancel_kitchen_tickets_for_order(
  p_order_id uuid,
  p_actor_staff_id uuid,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_actor uuid;
  v_actor_type public.audit_actor_type;
  v_reason text;
  v_count integer;
begin
  select *
    into v_order
    from public.orders o
   where o.id = p_order_id;

  if not found then
    return 0;
  end if;

  -- Explicit staff first, then the current authenticated staff identity. A
  -- privileged/system path with no staff identity is recorded as system; the
  -- order submitter is never used as a cancellation actor fallback.
  v_actor := coalesce(
    p_actor_staff_id,
    v_order.cancelled_by_staff_id,
    authz.current_staff_id()
  );
  v_actor_type := case
    when v_actor is null then 'system'::public.audit_actor_type
    else 'staff'::public.audit_actor_type
  end;
  v_reason := coalesce(
    nullif(btrim(p_reason), ''),
    nullif(btrim(v_order.cancellation_reason), ''),
    'Order cancelled'
  );

  -- Whole-order cancellation is the only path allowed to cancel completed
  -- kitchen items. Item-level removal is blocked by the item guard.
  perform set_config(
    'restaurant_platform.kitchen_allow_completed_cancel',
    'on',
    true
  );

  -- Items first, then tickets, matching the item -> ticket lock order used by
  -- the item-transition RPCs.
  update public.kitchen_ticket_items ti
     set status = 'cancelled',
         cancelled_at = coalesce(ti.cancelled_at, now()),
         cancelled_by_actor_type = v_actor_type,
         cancelled_by_staff_id = v_actor,
         cancellation_reason = coalesce(ti.cancellation_reason, v_reason)
    from public.kitchen_tickets t
   where ti.ticket_id = t.id
     and t.order_id = p_order_id
     and ti.status <> 'cancelled';

  get diagnostics v_count = row_count;

  update public.kitchen_tickets t
     set status = 'cancelled',
         cancelled_at = coalesce(t.cancelled_at, now()),
         cancelled_by_actor_type = v_actor_type,
         cancelled_by_staff_id = v_actor,
         cancellation_reason = coalesce(t.cancellation_reason, v_reason)
   where t.order_id = p_order_id
     and t.status <> 'cancelled';

  perform set_config(
    'restaurant_platform.kitchen_allow_completed_cancel',
    'off',
    true
  );

  return v_count;
end;
$$;

revoke all on function private.cancel_kitchen_tickets_for_order(uuid, uuid, text) from public;

comment on function private.cancel_kitchen_tickets_for_order(uuid, uuid, text) is
  'Cancels every non-cancelled ticket and ticket item when the parent order is cancelled. Staff and system cancellation domains are explicit; the order submitter is never used as a fallback actor.';

-- ---------------------------------------------------------------------------
-- 7. Order/order-item integration triggers
-- ---------------------------------------------------------------------------

create or replace function private.kitchen_on_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if new.status = 'accepted' then
    perform private.generate_kitchen_tickets(new.id, null);
  elsif new.status = 'cancelled' then
    perform private.cancel_kitchen_tickets_for_order(
      new.id,
      new.cancelled_by_staff_id,
      new.cancellation_reason
    );
  end if;

  return new;
end;
$$;

revoke all on function private.kitchen_on_order_status_change() from public;

create or replace function private.kitchen_on_order_item_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_status public.order_status;
begin
  select o.status
    into v_order_status
    from public.orders o
   where o.id = new.order_id;

  -- Items added while the order is already accepted must still reach the
  -- kitchen. Pending orders remain ticket-free until acceptance.
  if v_order_status = 'accepted' then
    perform private.generate_kitchen_tickets(new.order_id, new.id);
  end if;

  return new;
end;
$$;

revoke all on function private.kitchen_on_order_item_insert() from public;

create or replace function private.kitchen_on_order_item_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_actor uuid;
  v_actor_type public.audit_actor_type;
  v_reason text;
  v_ticket_id uuid;
begin
  if new.status <> 'cancelled'
     or old.status is not distinct from new.status
  then
    return new;
  end if;

  select *
    into v_order
    from public.orders o
   where o.id = new.order_id;

  v_actor := coalesce(
    new.cancelled_by_staff_id,
    v_order.cancelled_by_staff_id,
    authz.current_staff_id()
  );
  v_actor_type := case
    when v_actor is null then 'system'::public.audit_actor_type
    else 'staff'::public.audit_actor_type
  end;
  v_reason := coalesce(
    nullif(btrim(new.cancellation_reason), ''),
    nullif(btrim(v_order.cancellation_reason), ''),
    'Order item cancelled'
  );

  -- Item removal may cancel pending, preparing, or ready kitchen work, but it
  -- must never reverse completed kitchen history.
  if exists (
    select 1
      from public.kitchen_ticket_items ti
     where ti.order_item_id = new.id
       and ti.status = 'completed'
  ) then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Completed kitchen work cannot be cancelled or removed'
    );
  end if;

  for v_ticket_id in
    update public.kitchen_ticket_items ti
       set status = 'cancelled',
           cancelled_at = coalesce(ti.cancelled_at, now()),
           cancelled_by_actor_type = v_actor_type,
           cancelled_by_staff_id = v_actor,
           cancellation_reason = coalesce(ti.cancellation_reason, v_reason)
     where ti.order_item_id = new.id
       and ti.status <> 'cancelled'
     returning ti.ticket_id
  loop
    perform private.recalculate_kitchen_ticket_status(v_ticket_id);
  end loop;

  return new;
end;
$$;

revoke all on function private.kitchen_on_order_item_status_change() from public;

-- ---------------------------------------------------------------------------
-- 8. Audit for kitchen lifecycle transitions
-- ---------------------------------------------------------------------------

create or replace function private.audit_kitchen_ticket_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := authz.current_staff_id();
begin
  perform private.audit_write(
    case
      when v_actor is null then 'system'::public.audit_actor_type
      else 'staff'::public.audit_actor_type
    end,
    v_actor,
    null,
    new.organization_id,
    new.branch_id,
    'kitchen.ticket_created',
    'kitchen_ticket',
    new.id,
    null,
    jsonb_build_object(
      'order_id', new.order_id,
      'station_id', new.station_id,
      'generation', new.generation,
      'status', new.status
    )
  );

  return new;
end;
$$;

revoke all on function private.audit_kitchen_ticket_insert() from public;

create or replace function private.audit_kitchen_ticket_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_actor_type public.audit_actor_type;
  v_metadata jsonb;
begin
  if new.status is distinct from old.status then
    if new.status = 'cancelled' then
      v_actor := new.cancelled_by_staff_id;
      v_actor_type := new.cancelled_by_actor_type;
    else
      v_actor := authz.current_staff_id();
      v_actor_type := case
        when v_actor is null then 'system'::public.audit_actor_type
        else 'staff'::public.audit_actor_type
      end;
    end if;

    v_metadata := jsonb_build_object(
      'order_id', new.order_id,
      'station_id', new.station_id,
      'generation', new.generation,
      'from_status', old.status,
      'to_status', new.status
    );

    if new.status = 'cancelled' then
      v_metadata := v_metadata || jsonb_build_object(
        'cancelled_by_actor_type', new.cancelled_by_actor_type,
        'cancelled_by_staff_id', new.cancelled_by_staff_id
      );
    end if;

    perform private.audit_write(
      v_actor_type,
      v_actor,
      null,
      new.organization_id,
      new.branch_id,
      'kitchen.ticket_status_changed',
      'kitchen_ticket',
      new.id,
      new.cancellation_reason,
      v_metadata
    );
  end if;

  return new;
end;
$$;

revoke all on function private.audit_kitchen_ticket_status_change() from public;

create or replace function private.audit_kitchen_ticket_item_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_actor_type public.audit_actor_type;
  v_metadata jsonb;
begin
  if new.status is distinct from old.status then
    if new.status = 'cancelled' then
      v_actor := new.cancelled_by_staff_id;
      v_actor_type := new.cancelled_by_actor_type;
    else
      v_actor := authz.current_staff_id();
      v_actor_type := case
        when v_actor is null then 'system'::public.audit_actor_type
        else 'staff'::public.audit_actor_type
      end;
    end if;

    v_metadata := jsonb_build_object(
      'ticket_id', new.ticket_id,
      'order_id', new.order_id,
      'order_item_id', new.order_item_id,
      'from_status', old.status,
      'to_status', new.status
    );

    if new.status = 'cancelled' then
      v_metadata := v_metadata || jsonb_build_object(
        'cancelled_by_actor_type', new.cancelled_by_actor_type,
        'cancelled_by_staff_id', new.cancelled_by_staff_id
      );
    end if;

    perform private.audit_write(
      v_actor_type,
      v_actor,
      null,
      new.organization_id,
      new.branch_id,
      'kitchen.ticket_item_status_changed',
      'kitchen_ticket_item',
      new.id,
      new.cancellation_reason,
      v_metadata
    );
  end if;

  return new;
end;
$$;

revoke all on function private.audit_kitchen_ticket_item_status_change() from public;

-- ---------------------------------------------------------------------------
-- 9. Read-only routing diagnostics
-- ---------------------------------------------------------------------------

create or replace function public.list_kitchen_routing_issues(p_branch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_issues jsonb;
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
    array['owner', 'admin', 'manager']::text[]
  );

  with issue_rows as (
    select jsonb_build_object(
             'issueType', 'inactive_item_route',
             'branchId', p_branch_id,
             'menuItemId', mi.id,
             'menuItemName', mi.name,
             'menuCategoryId', mc.id,
             'menuCategoryName', mc.name,
             'stationId', ks.id,
             'stationName', ks.name,
             'stationStatus', ks.status,
             'categoryRouteActive', exists (
               select 1
                 from public.kitchen_station_menu_categories cr
                 join public.kitchen_stations cs
                   on cs.id = cr.station_id
                where cr.organization_id = v_org_id
                  and cr.branch_id = p_branch_id
                  and cr.menu_category_id = mi.category_id
                  and cs.organization_id = v_org_id
                  and cs.branch_id = p_branch_id
                  and cs.status = 'active'
             )
           ) as issue
      from public.kitchen_station_menu_items r
      join public.menu_items mi on mi.id = r.menu_item_id
      join public.menu_categories mc on mc.id = mi.category_id
      join public.kitchen_stations ks on ks.id = r.station_id
     where r.organization_id = v_org_id
       and r.branch_id = p_branch_id
       and ks.organization_id = v_org_id
       and ks.branch_id = p_branch_id
       and ks.status = 'inactive'
    union all
    select jsonb_build_object(
             'issueType', 'inactive_category_route',
             'branchId', p_branch_id,
             'menuCategoryId', mc.id,
             'menuCategoryName', mc.name,
             'stationId', ks.id,
             'stationName', ks.name,
             'stationStatus', ks.status
           ) as issue
      from public.kitchen_station_menu_categories r
      join public.menu_categories mc on mc.id = r.menu_category_id
      join public.kitchen_stations ks on ks.id = r.station_id
     where r.organization_id = v_org_id
       and r.branch_id = p_branch_id
       and ks.organization_id = v_org_id
       and ks.branch_id = p_branch_id
       and ks.status = 'inactive'
  )
  select coalesce(
           jsonb_agg(
             issue
             order by issue ->> 'issueType',
                      issue ->> 'menuItemId',
                      issue ->> 'menuCategoryId',
                      issue ->> 'stationId'
           ),
           '[]'::jsonb
         )
    into v_issues
    from issue_rows;

  return jsonb_build_object(
    'branchId', p_branch_id,
    'issues', v_issues
  );
end;
$$;

revoke all on function public.list_kitchen_routing_issues(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.list_kitchen_routing_issues(uuid) to authenticated';
  end if;
end
$$;

comment on function public.list_kitchen_routing_issues(uuid) is
  'Read-only routing diagnostics for Owner/Admin/Manager. Reports inactive item-level routes (including whether an active category route exists) and inactive category routes for one accessible branch.';
