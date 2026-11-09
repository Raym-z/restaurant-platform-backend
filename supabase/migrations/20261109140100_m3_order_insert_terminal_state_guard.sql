-- M3 core POS operations: defense-in-depth guard for direct terminal-state
-- order inserts.
--
-- 20261108110800_m3_order_state_guards.sql enforces terminal-state invariants
-- for status UPDATEs. Its trigger is deliberately `BEFORE UPDATE OF status`, so
-- a privileged direct INSERT (table owner, migration, or backend job) could
-- previously create a terminal order that bypassed the RPC guards.
--
-- This migration:
--   * Extracts the terminal-state invariants into a reusable private helper.
--   * Replaces the status-transition function so INSERT and UPDATE paths use
--     the same validation helper.
--   * Adds a dedicated BEFORE INSERT trigger for public.orders.
--
-- Normal order creation inserts `pending` and is unaffected. Authenticated,
-- anon, and service_role have no INSERT privilege on public.orders; this is
-- defense in depth for privileged write paths only.

create or replace function private.assert_order_terminal_state(
  p_order_id uuid,
  p_status public.order_status,
  p_cancelled_at timestamptz,
  p_cancelled_by_staff_id uuid,
  p_cancellation_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status = 'cancelled' then
    if p_cancelled_at is null
       or p_cancelled_by_staff_id is null
       or nullif(btrim(p_cancellation_reason), '') is null
    then
      perform private.raise_app_error(
        'ORDER_INVALID_STATUS',
        'Cancellation requires a timestamp, an actor, and a non-empty reason'
      );
    end if;

    return;
  end if;

  -- Completed/served terminal states must not get ahead of non-cancelled items.
  -- A direct INSERT cannot create child items before the order row exists, so
  -- inserting a fulfilled terminal order is always rejected by this check.
  if p_status in ('served', 'completed') then
    if not exists (
      select 1
      from public.order_items oi
      where oi.order_id = p_order_id
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
      where oi.order_id = p_order_id
        and oi.status <> 'cancelled'
        and oi.status <> 'served'
    ) then
      perform private.raise_app_error(
        'ORDER_INVALID_STATUS',
        'All non-cancelled items must be served before the order can be served or completed'
      );
    end if;
  end if;
end;
$$;

revoke all on function private.assert_order_terminal_state(
  uuid,
  public.order_status,
  timestamptz,
  uuid,
  text
) from public;

comment on function private.assert_order_terminal_state(
  uuid,
  public.order_status,
  timestamptz,
  uuid,
  text
) is
  'Validates a terminal order row. Cancellation requires timestamp, actor, and non-empty reason. Served/completed require at least one non-cancelled item and every such item served.';

create or replace function private.guard_order_status_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowed boolean := false;
begin
  -- The transition matrix applies to UPDATEs. INSERT can only be checked
  -- against the terminal-state invariants that do not depend on a prior status.
  if tg_op = 'INSERT' then
    perform private.assert_order_terminal_state(
      new.id,
      new.status,
      new.cancelled_at,
      new.cancelled_by_staff_id,
      new.cancellation_reason
    );

    return new;
  end if;

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
  end if;

  perform private.assert_order_terminal_state(
    new.id,
    new.status,
    new.cancelled_at,
    new.cancelled_by_staff_id,
    new.cancellation_reason
  );

  return new;
end;
$$;

revoke all on function private.guard_order_status_transition() from public;

comment on function private.guard_order_status_transition() is
  'Enforces pending -> accepted -> preparing -> ready -> served -> completed, with cancellation allowed before served. Served/completed require at least one non-cancelled item and all such items served. Also validates terminal-state invariants for direct INSERTs.';

-- Keep the existing UPDATE trigger and add a separate INSERT trigger so the
-- execution paths remain explicit. Both call the same transition function.
drop trigger if exists orders_guard_insert_terminal_state on public.orders;

create trigger orders_guard_insert_terminal_state
  before insert on public.orders
  for each row execute function private.guard_order_status_transition();

comment on trigger orders_guard_insert_terminal_state on public.orders is
  'Rejects direct terminal-state INSERTs that lack cancellation metadata or fulfilled items. Normal pending inserts are unaffected.';
