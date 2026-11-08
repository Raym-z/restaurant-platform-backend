-- M3 core POS operations: database-level lifecycle and editability guards.
--
-- RPCs remain the only supported write path for authenticated clients, but these
-- triggers ensure the invariants hold even for privileged/backend writes:
--   * Historical order and item snapshots stay immutable.
--   * Quantity and subtotal can change only while an order is still mutable.
--   * Only the approved order state transitions are accepted.
--   * Cancellation always records actor, timestamp, and reason.
--   * A dining session cannot close while non-terminal orders remain.
--
-- This migration runs after the `completed` enum addition in
-- 20261108110700_m3_order_schema_extensions.sql.

create or replace function private.guard_order_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.branch_id is distinct from old.branch_id
     or new.dining_session_id is distinct from old.dining_session_id
     or new.source is distinct from old.source
     or new.currency_code is distinct from old.currency_code
     or new.submitted_by_staff_id is distinct from old.submitted_by_staff_id
     or new.order_reference is distinct from old.order_reference
     or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'P0001',
      message = 'ORDER_IMMUTABLE';
  end if;

  -- Subtotal may be recalculated only while the order is still editable.
  -- `accepted` is the existing database value for the wire-level "confirmed"
  -- state that precedes kitchen preparation.
  if new.subtotal_minor is distinct from old.subtotal_minor
     and old.status not in ('pending', 'accepted')
  then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Order totals cannot be changed after preparation has started'
    );
  end if;

  return new;
end;
$$;

revoke all on function private.guard_order_snapshot() from public;

comment on function private.guard_order_snapshot() is
  'Blocks tenant/source/currency/reference snapshot changes. Allows subtotal recalculation only while pending or accepted.';

create or replace function private.guard_order_item_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_status public.order_status;
begin
  if new.order_id is distinct from old.order_id
     or new.organization_id is distinct from old.organization_id
     or new.branch_id is distinct from old.branch_id
     or new.menu_item_id is distinct from old.menu_item_id
     or new.item_name_snapshot is distinct from old.item_name_snapshot
     or new.base_unit_price_minor is distinct from old.base_unit_price_minor
     or new.modifier_unit_delta_minor is distinct from old.modifier_unit_delta_minor
     or new.currency_code is distinct from old.currency_code
     or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'P0001',
      message = 'ORDER_ITEM_IMMUTABLE';
  end if;

  -- Quantity is editable only before kitchen preparation starts. Price and
  -- name snapshots remain immutable at every lifecycle stage.
  if new.quantity is distinct from old.quantity then
    select o.status
      into v_order_status
      from public.orders o
     where o.id = new.order_id;

    if v_order_status is null
       or v_order_status not in ('pending', 'accepted')
    then
      perform private.raise_app_error(
        'ORDER_MODIFICATION_NOT_ALLOWED',
        'Order item quantity cannot be changed after preparation has started'
      );
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.guard_order_item_snapshot() from public;

comment on function private.guard_order_item_snapshot() is
  'Blocks historical item snapshot changes. Allows quantity changes only before kitchen preparation.';

create or replace function private.guard_order_status_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowed boolean := false;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status = 'pending'
     and new.status in ('accepted', 'cancelled')
  then
    v_allowed := true;
  elsif old.status = 'accepted'
        and new.status in ('preparing', 'cancelled')
  then
    v_allowed := true;
  elsif old.status = 'preparing'
        and new.status in ('ready', 'cancelled')
  then
    v_allowed := true;
  elsif old.status = 'ready'
        and new.status in ('served', 'cancelled')
  then
    v_allowed := true;
  elsif old.status = 'served'
        and new.status = 'completed'
  then
    v_allowed := true;
  end if;

  if not v_allowed then
    perform private.raise_app_error(
      'ORDER_INVALID_STATUS',
      'The requested order status transition is not permitted'
    );
  end if;

  if new.status = 'accepted' then
    new.accepted_at := coalesce(new.accepted_at, now());
  elsif new.status = 'preparing' then
    new.preparing_at := coalesce(new.preparing_at, now());
  elsif new.status = 'ready' then
    new.ready_at := coalesce(new.ready_at, now());
  elsif new.status = 'served' then
    new.served_at := coalesce(new.served_at, now());
  elsif new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  elsif new.status = 'cancelled' then
    if new.cancelled_at is null
       or new.cancelled_by_staff_id is null
       or nullif(btrim(new.cancellation_reason), '') is null
    then
      perform private.raise_app_error(
        'ORDER_INVALID_STATUS',
        'Cancellation requires a timestamp, an actor, and a non-empty reason'
      );
    end if;
  end if;

  -- Order-level served/completed must not get ahead of non-cancelled items,
  -- and an order whose only items were removed cannot reach a terminal
  -- fulfilled state. Such an order must be cancelled instead.
  if new.status in ('served', 'completed') then
    if not exists (
      select 1
      from public.order_items oi
      where oi.order_id = new.id
        and oi.status <> 'cancelled'
    ) then
      perform private.raise_app_error(
        'ORDER_INVALID_STATUS',
        'An order must have at least one non-cancelled item before it can be served or completed'
      );
    end if;

    if exists (
      select 1
      from public.order_items oi
      where oi.order_id = new.id
        and oi.status <> 'cancelled'
        and oi.status <> 'served'
    ) then
      perform private.raise_app_error(
        'ORDER_INVALID_STATUS',
        'All non-cancelled items must be served before the order can be served or completed'
      );
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.guard_order_status_transition() from public;

drop trigger if exists orders_guard_status_transition on public.orders;

create trigger orders_guard_status_transition
  before update of status on public.orders
  for each row execute function private.guard_order_status_transition();

comment on function private.guard_order_status_transition() is
  'Enforces pending -> accepted -> preparing -> ready -> served -> completed, with cancellation allowed before served. Served/completed require at least one non-cancelled item and all such items served.';

create or replace function private.guard_dining_session_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'closed' and new.status <> 'closed' then
    perform private.raise_app_error(
      'SESSION_ALREADY_CLOSED',
      'A closed dining session cannot be reopened'
    );
  end if;

  if new.status = 'closed' and old.status = 'active' then
    if new.closed_at is null then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'A closing timestamp is required'
      );
    end if;

    if new.closed_by_staff_id is null then
      perform private.raise_app_error(
        'VALIDATION_ERROR',
        'A closing staff member is required'
      );
    end if;

    if exists (
      select 1
      from public.orders o
      where o.dining_session_id = new.id
        and o.status not in ('completed', 'cancelled')
    ) then
      perform private.raise_app_error(
        'SESSION_BALANCE_OUTSTANDING',
        'All orders must be completed or cancelled before the dining session can close'
      );
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.guard_dining_session_lifecycle() from public;

drop trigger if exists dining_sessions_guard_lifecycle on public.dining_sessions;

create trigger dining_sessions_guard_lifecycle
  before update of status on public.dining_sessions
  for each row execute function private.guard_dining_session_lifecycle();

comment on function private.guard_dining_session_lifecycle() is
  'Prevents reopening closed sessions and blocks closure while non-terminal orders remain.';

comment on column public.orders.subtotal_minor is
  'Order-level subtotal snapshot. Recalculated from non-cancelled item lines while pending/accepted; immutable once preparation starts.';
