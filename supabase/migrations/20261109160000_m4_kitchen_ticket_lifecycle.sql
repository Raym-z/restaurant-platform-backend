-- M4.2: Order integration and kitchen ticket lifecycle.
--
-- Scope:
--   * Generate kitchen tickets atomically when an order becomes accepted.
--   * Resolve item-level routing before category-level routing, using only
--     active stations.
--   * Keep independent kitchen item preparation state so the M3 order-status
--     cascade cannot overwrite kitchen progress.
--   * Aggregate ticket status from ticket-item state.
--   * Propagate order and order-item cancellation into kitchen state.
--   * Expose secure item-transition RPCs; direct client writes stay denied.
--
-- M3 `order_items.status` remains the order-lifecycle state. Kitchen state is
-- stored separately on `kitchen_ticket_items` so existing M3 cascades continue
-- to work without being rewritten or overloaded.
--
-- Design: docs/m4-kitchen-ticket-lifecycle.md.

-- ---------------------------------------------------------------------------
-- 1. Independent kitchen ticket-item lifecycle state
-- ---------------------------------------------------------------------------

alter table public.kitchen_ticket_items
  add column if not exists status public.kitchen_ticket_status not null default 'pending',
  add column if not exists started_at timestamptz,
  add column if not exists ready_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by_staff_id uuid,
  add column if not exists cancellation_reason text,
  add column if not exists updated_at timestamptz not null default now();

alter table public.kitchen_ticket_items
  add constraint kitchen_ticket_items_cancellation_check check (
    status <> 'cancelled'
    or (
      cancelled_at is not null
      and cancelled_by_staff_id is not null
      and nullif(btrim(cancellation_reason), '') is not null
    )
  ),
  add constraint kitchen_ticket_items_cancelled_by_organization_fkey
    foreign key (cancelled_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict;

create index if not exists kitchen_ticket_items_ticket_status_idx
  on public.kitchen_ticket_items (ticket_id, status);

create trigger kitchen_ticket_items_set_updated_at
  before update on public.kitchen_ticket_items
  for each row execute function private.set_updated_at();

comment on column public.kitchen_ticket_items.status is
  'Independent kitchen preparation state: pending, preparing, ready, completed, or cancelled. It is not overwritten by M3 order-item status cascades.';

comment on column public.kitchen_ticket_items.started_at is
  'First time kitchen preparation began for this ticket item.';

comment on column public.kitchen_ticket_items.ready_at is
  'When this ticket item became ready for pickup.';

comment on column public.kitchen_ticket_items.completed_at is
  'When this ticket item completed kitchen processing.';

comment on column public.kitchen_ticket_items.cancelled_at is
  'When this ticket item was cancelled, either directly or because its order/order item was cancelled.';

comment on column public.kitchen_ticket_items.cancelled_by_staff_id is
  'Staff actor recorded when the ticket item was cancelled.';

comment on column public.kitchen_ticket_items.cancellation_reason is
  'Human-readable cancellation reason copied from the order/order-item cancellation workflow.';

-- ---------------------------------------------------------------------------
-- 2. Read helpers for RPC responses
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
    'status', t.status,
    'startedAt', t.started_at,
    'readyAt', t.ready_at,
    'completedAt', t.completed_at,
    'cancelledAt', t.cancelled_at,
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
-- 3. Lifecycle guards (defense in depth for privileged writes)
-- ---------------------------------------------------------------------------

create or replace function private.guard_kitchen_ticket_item_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
    new.cancelled_at := coalesce(new.cancelled_at, now());

    if new.cancelled_by_staff_id is null
       or nullif(btrim(new.cancellation_reason), '') is null
    then
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'Cancellation requires an actor and a non-empty reason'
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
  'Enforces pending -> preparing -> ready -> completed and cancellation from any non-cancelled state. Rejects backward and skipped transitions.';

create trigger kitchen_ticket_items_guard_status
  before update of status on public.kitchen_ticket_items
  for each row execute function private.guard_kitchen_ticket_item_status();

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

  if new.status = 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());

    if new.cancelled_by_staff_id is null
       or nullif(btrim(new.cancellation_reason), '') is null
    then
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'Cancellation requires an actor and a non-empty reason'
      );
    end if;

    return new;
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

  if v_total = 0 or v_active = 0 then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'A non-cancelled kitchen ticket must contain at least one active item'
    );
  end if;

  if new.status = 'pending'
     and (v_preparing + v_ready + v_completed) > 0
  then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'A pending ticket cannot have started items'
    );
  elsif new.status = 'preparing'
        and (v_preparing + v_ready + v_completed) = 0
  then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'A preparing ticket must have at least one started item'
    );
  elsif new.status = 'ready'
        and (v_ready + v_completed) <> v_active
  then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'A ready ticket requires every active item to be ready or completed'
    );
  elsif new.status = 'completed'
        and v_completed <> v_active
  then
    perform private.raise_app_error(
      'KITCHEN_TICKET_INCONSISTENT',
      'A completed ticket requires every active item to be completed'
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
  'Rejects ticket status changes that are inconsistent with the current ticket-item states. Cancelled is terminal and requires attribution.';

create trigger kitchen_tickets_guard_status
  before update of status on public.kitchen_tickets
  for each row execute function private.guard_kitchen_ticket_status();

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
  -- completed ticket.
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
    select ti.cancelled_by_staff_id, ti.cancellation_reason
      into v_actor, v_reason
      from public.kitchen_ticket_items ti
     where ti.ticket_id = p_ticket_id
       and ti.status = 'cancelled'
     order by ti.cancelled_at desc nulls last, ti.id
     limit 1;

    if v_actor is null then
      select coalesce(o.cancelled_by_staff_id, o.submitted_by_staff_id)
        into v_actor
        from public.orders o
       where o.id = v_ticket.order_id;
    end if;

    v_reason := coalesce(
      nullif(btrim(v_reason), ''),
      'All kitchen ticket items were cancelled'
    );

    if v_actor is null then
      perform private.raise_app_error(
        'KITCHEN_CANCELLATION_INVALID',
        'A cancellation actor is required when all kitchen ticket items are cancelled'
      );
    end if;

    update public.kitchen_tickets
       set status = 'cancelled',
           cancelled_at = coalesce(cancelled_at, now()),
           cancelled_by_staff_id = coalesce(cancelled_by_staff_id, v_actor),
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
  'Derives kitchen ticket status from active ticket items: pending, preparing, ready, completed, or cancelled when every item is cancelled. Cancelled tickets are never recomputed as completed.';

-- ---------------------------------------------------------------------------
-- 5. Idempotent ticket generation
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
  v_inserted integer;
  v_created integer := 0;
  v_ticket_ids uuid[] := '{}';
begin
  select *
    into v_order
    from public.orders o
   where o.id = p_order_id;

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
    v_inserted := 0;

    insert into public.kitchen_tickets (
      organization_id,
      branch_id,
      order_id,
      station_id,
      status
    )
    values (
      v_order.organization_id,
      v_order.branch_id,
      p_order_id,
      v_route.station_id,
      'pending'
    )
    on conflict (order_id, station_id) do nothing
    returning id into v_ticket_id;

    get diagnostics v_inserted = row_count;

    if v_ticket_id is null then
      select t.id
        into v_ticket_id
        from public.kitchen_tickets t
       where t.order_id = p_order_id
         and t.station_id = v_route.station_id;
    end if;

    -- Defensive: a concurrent transaction should have made the ticket visible
    -- by the time the blocking insert completed. Never create duplicate work.
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
  'Idempotently resolves active station routing and creates one ticket per (order, station) with ticket items. Item-level routing overrides category routing. Unrouted items are skipped.';

-- ---------------------------------------------------------------------------
-- 6. Cancellation propagation
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

  v_actor := coalesce(
    p_actor_staff_id,
    v_order.cancelled_by_staff_id,
    v_order.submitted_by_staff_id
  );
  v_reason := coalesce(
    nullif(btrim(p_reason), ''),
    nullif(btrim(v_order.cancellation_reason), ''),
    'Order cancelled'
  );

  if v_actor is null then
    perform private.raise_app_error(
      'KITCHEN_CANCELLATION_INVALID',
      'A cancellation actor is required'
    );
  end if;

  -- Items first, then tickets, matching the item -> ticket lock order used by
  -- the item-transition RPCs.
  update public.kitchen_ticket_items ti
     set status = 'cancelled',
         cancelled_at = coalesce(ti.cancelled_at, now()),
         cancelled_by_staff_id = coalesce(ti.cancelled_by_staff_id, v_actor),
         cancellation_reason = coalesce(ti.cancellation_reason, v_reason)
    from public.kitchen_tickets t
   where ti.ticket_id = t.id
     and t.order_id = p_order_id
     and ti.status <> 'cancelled';

  get diagnostics v_count = row_count;

  update public.kitchen_tickets t
     set status = 'cancelled',
         cancelled_at = coalesce(t.cancelled_at, now()),
         cancelled_by_staff_id = coalesce(t.cancelled_by_staff_id, v_actor),
         cancellation_reason = coalesce(t.cancellation_reason, v_reason)
   where t.order_id = p_order_id
     and t.status <> 'cancelled';

  return v_count;
end;
$$;

revoke all on function private.cancel_kitchen_tickets_for_order(uuid, uuid, text) from public;

comment on function private.cancel_kitchen_tickets_for_order(uuid, uuid, text) is
  'Cancels every non-cancelled ticket and ticket item when the parent order is cancelled. Cancellation attribution is copied from the order workflow.';

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

create trigger orders_generate_and_cancel_kitchen_tickets
  after update of status on public.orders
  for each row execute function private.kitchen_on_order_status_change();

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

create trigger order_items_generate_kitchen_tickets
  after insert on public.order_items
  for each row execute function private.kitchen_on_order_item_insert();

create or replace function private.kitchen_on_order_item_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_actor uuid;
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
    v_order.submitted_by_staff_id
  );
  v_reason := coalesce(
    nullif(btrim(new.cancellation_reason), ''),
    nullif(btrim(v_order.cancellation_reason), ''),
    'Order item cancelled'
  );

  if v_actor is null then
    perform private.raise_app_error(
      'KITCHEN_CANCELLATION_INVALID',
      'A cancellation actor is required'
    );
  end if;

  for v_ticket_id in
    update public.kitchen_ticket_items ti
       set status = 'cancelled',
           cancelled_at = coalesce(ti.cancelled_at, now()),
           cancelled_by_staff_id = coalesce(ti.cancelled_by_staff_id, v_actor),
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

create trigger order_items_cancel_kitchen_tickets
  after update of status on public.order_items
  for each row execute function private.kitchen_on_order_item_status_change();

-- ---------------------------------------------------------------------------
-- 8. Audit for meaningful kitchen lifecycle transitions
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
      'status', new.status
    )
  );

  return new;
end;
$$;

revoke all on function private.audit_kitchen_ticket_insert() from public;

create trigger kitchen_tickets_audit_insert
  after insert on public.kitchen_tickets
  for each row execute function private.audit_kitchen_ticket_insert();

create or replace function private.audit_kitchen_ticket_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := authz.current_staff_id();
begin
  if new.status is distinct from old.status then
    perform private.audit_write(
      case
        when v_actor is null then 'system'::public.audit_actor_type
        else 'staff'::public.audit_actor_type
      end,
      v_actor,
      null,
      new.organization_id,
      new.branch_id,
      'kitchen.ticket_status_changed',
      'kitchen_ticket',
      new.id,
      new.cancellation_reason,
      jsonb_build_object(
        'order_id', new.order_id,
        'station_id', new.station_id,
        'from_status', old.status,
        'to_status', new.status
      )
    );
  end if;

  return new;
end;
$$;

revoke all on function private.audit_kitchen_ticket_status_change() from public;

create trigger kitchen_tickets_audit_status_change
  after update of status on public.kitchen_tickets
  for each row execute function private.audit_kitchen_ticket_status_change();

create or replace function private.audit_kitchen_ticket_item_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := authz.current_staff_id();
begin
  if new.status is distinct from old.status then
    perform private.audit_write(
      case
        when v_actor is null then 'system'::public.audit_actor_type
        else 'staff'::public.audit_actor_type
      end,
      v_actor,
      null,
      new.organization_id,
      new.branch_id,
      'kitchen.ticket_item_status_changed',
      'kitchen_ticket_item',
      new.id,
      new.cancellation_reason,
      jsonb_build_object(
        'ticket_id', new.ticket_id,
        'order_id', new.order_id,
        'order_item_id', new.order_item_id,
        'from_status', old.status,
        'to_status', new.status
      )
    );
  end if;

  return new;
end;
$$;

revoke all on function private.audit_kitchen_ticket_item_status_change() from public;

create trigger kitchen_ticket_items_audit_status_change
  after update of status on public.kitchen_ticket_items
  for each row execute function private.audit_kitchen_ticket_item_status_change();

-- ---------------------------------------------------------------------------
-- 9. Secure item-transition RPCs
-- ---------------------------------------------------------------------------

create or replace function private.transition_kitchen_ticket_item(
  p_ticket_item_id uuid,
  p_target_status public.kitchen_ticket_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_item public.kitchen_ticket_items%rowtype;
  v_ticket public.kitchen_tickets%rowtype;
  v_ticket_id uuid;
  v_order_status public.order_status;
begin
  perform authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  if p_target_status not in ('preparing', 'ready', 'completed') then
    perform private.raise_app_error(
      'KITCHEN_INVALID_TRANSITION',
      'Only preparing, ready, and completed are accepted as client transitions'
    );
  end if;

  select ti.ticket_id
    into v_ticket_id
    from public.kitchen_ticket_items ti
   where ti.id = p_ticket_item_id;

  if v_ticket_id is null then
    perform private.raise_app_error(
      'KITCHEN_TICKET_ITEM_NOT_FOUND',
      'Kitchen ticket item was not found'
    );
  end if;

  -- Lock item then ticket. Every cancellation path uses the same order.
  select *
    into v_item
    from public.kitchen_ticket_items ti
   where ti.id = p_ticket_item_id
   for update;

  select *
    into v_ticket
    from public.kitchen_tickets t
   where t.id = v_item.ticket_id
   for update;

  if v_ticket.organization_id is distinct from v_org_id then
    perform private.raise_app_error(
      'KITCHEN_TICKET_ITEM_NOT_FOUND',
      'Kitchen ticket item was not found'
    );
  end if;

  perform authz.assert_branch_role(
    v_ticket.branch_id,
    array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
  );

  if v_ticket.status = 'cancelled' or v_item.status = 'cancelled' then
    perform private.raise_app_error(
      'KITCHEN_TICKET_CANCELLED',
      'A cancelled kitchen ticket cannot be changed'
    );
  end if;

  select o.status
    into v_order_status
    from public.orders o
   where o.id = v_ticket.order_id;

  if v_order_status = 'cancelled' then
    perform private.raise_app_error(
      'KITCHEN_TICKET_CANCELLED',
      'The parent order is cancelled'
    );
  end if;

  -- Repeated identical requests are safe no-ops and do not add audit noise.
  if v_item.status = p_target_status then
    return private.kitchen_ticket_json(v_ticket.id);
  end if;

  if not (
    (v_item.status = 'pending' and p_target_status = 'preparing')
    or (v_item.status = 'preparing' and p_target_status = 'ready')
    or (v_item.status = 'ready' and p_target_status = 'completed')
  ) then
    perform private.raise_app_error(
      'KITCHEN_INVALID_TRANSITION',
      'The requested kitchen ticket item transition is not permitted'
    );
  end if;

  update public.kitchen_ticket_items
     set status = p_target_status,
         started_at = case
           when p_target_status = 'preparing' then coalesce(started_at, now())
           else started_at
         end,
         ready_at = case
           when p_target_status = 'ready' then coalesce(ready_at, now())
           else ready_at
         end,
         completed_at = case
           when p_target_status = 'completed' then coalesce(completed_at, now())
           else completed_at
         end
   where id = p_ticket_item_id;

  perform private.recalculate_kitchen_ticket_status(v_ticket.id);

  return private.kitchen_ticket_json(v_ticket.id);
end;
$$;

revoke all on function private.transition_kitchen_ticket_item(
  uuid,
  public.kitchen_ticket_status
) from public;

create or replace function public.start_kitchen_ticket_item(p_ticket_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return private.transition_kitchen_ticket_item(
    p_ticket_item_id,
    'preparing'::public.kitchen_ticket_status
  );
end;
$$;

create or replace function public.mark_kitchen_ticket_item_ready(p_ticket_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return private.transition_kitchen_ticket_item(
    p_ticket_item_id,
    'ready'::public.kitchen_ticket_status
  );
end;
$$;

create or replace function public.complete_kitchen_ticket_item(p_ticket_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return private.transition_kitchen_ticket_item(
    p_ticket_item_id,
    'completed'::public.kitchen_ticket_status
  );
end;
$$;

revoke all on function public.start_kitchen_ticket_item(uuid) from public;
revoke all on function public.mark_kitchen_ticket_item_ready(uuid) from public;
revoke all on function public.complete_kitchen_ticket_item(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.start_kitchen_ticket_item(uuid) to authenticated';
    execute 'grant execute on function public.mark_kitchen_ticket_item_ready(uuid) to authenticated';
    execute 'grant execute on function public.complete_kitchen_ticket_item(uuid) to authenticated';
  end if;
end
$$;

comment on function public.start_kitchen_ticket_item(uuid) is
  'Moves one kitchen ticket item from pending to preparing and recalculates its ticket. Requires an Owner/Admin/Manager/Kitchen Staff branch role.';

comment on function public.mark_kitchen_ticket_item_ready(uuid) is
  'Moves one kitchen ticket item from preparing to ready and recalculates its ticket. Requires an Owner/Admin/Manager/Kitchen Staff branch role.';

comment on function public.complete_kitchen_ticket_item(uuid) is
  'Moves one kitchen ticket item from ready to completed and recalculates its ticket. Requires an Owner/Admin/Manager/Kitchen Staff branch role.';
