-- M4.2 final corrections: order-status/kitchen-item removal policy, direct
-- ticket-item invariants, and cancellation-attribution immutability.
--
-- Additive to 20261109160000 and 20261109170000. This migration does not
-- rewrite migration history.

-- ---------------------------------------------------------------------------
-- 1. D7: kitchen-state-aware item removal
-- ---------------------------------------------------------------------------

-- The original M3 guard permits subtotal recalculation only while the order is
-- pending or accepted. Removing an item from an order that is already preparing
-- or ready is now allowed when the kitchen item itself is pending/preparing/
-- ready, so the subtotal must be recalculated for that narrowly scoped path.
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

  -- Subtotal may be recalculated while the order is still editable. A
  -- transaction-local flag allows the same recalculation for a preparing/ready
  -- order only when remove_order_item has already validated the kitchen items.
  if new.subtotal_minor is distinct from old.subtotal_minor
     and old.status not in ('pending', 'accepted')
     and not (
       old.status in ('preparing', 'ready')
       and coalesce(
         current_setting(
           'restaurant_platform.order_allow_item_removal_subtotal',
           true
         ),
         'off'
       ) = 'on'
     )
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
  'Blocks tenant/source/currency/reference snapshot changes. Allows subtotal recalculation while pending/accepted, or while preparing/ready only through the guarded item-removal path.';

create or replace function public.remove_order_item(
  p_order_item_id uuid,
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
  v_item public.order_items%rowtype;
  v_order public.orders%rowtype;
  v_reason text;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select *
    into v_item
    from public.order_items oi
   where oi.id = p_order_item_id;

  if not found then
    perform private.raise_app_error('ORDER_ITEM_NOT_FOUND', 'Order item was not found');
  end if;

  select *
    into v_order
    from public.orders o
   where o.id = v_item.order_id;

  if not found or v_order.organization_id is distinct from v_org_id then
    perform private.raise_app_error('ORDER_ITEM_NOT_FOUND', 'Order item was not found');
  end if;

  perform authz.assert_branch_role(
    v_order.branch_id,
    array['owner', 'admin', 'manager', 'cashier']::text[]
  );

  v_reason := coalesce(nullif(btrim(p_reason), ''), 'Removed from order');

  if length(v_reason) > 500 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Removal reason cannot exceed 500 characters');
  end if;

  select *
    into v_order
    from public.orders o
   where o.id = v_item.order_id
   for update;

  select *
    into v_item
    from public.order_items oi
   where oi.id = p_order_item_id
   for update;

  perform 1
    from public.dining_sessions ds
   where ds.id = v_order.dining_session_id
   for share;

  if not exists (
    select 1
    from public.dining_sessions ds
    where ds.id = v_order.dining_session_id
      and ds.status = 'active'
  ) then
    perform private.raise_app_error('SESSION_NOT_ACTIVE', 'The dining session is not active');
  end if;

  -- Removal is allowed while the order is pending/accepted, or while it is
  -- preparing/ready and the matching kitchen ticket items are still removable.
  -- Served, completed, and cancelled orders remain terminal for item removal.
  if v_order.status not in ('pending', 'accepted', 'preparing', 'ready') then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Items cannot be removed after the order is served, completed, or cancelled'
    );
  end if;

  if v_item.status = 'cancelled' then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'The order item is already cancelled'
    );
  end if;

  -- This is also enforced by the M4 item-cancellation trigger. Checking it here
  -- gives the removal RPC a deterministic pre-write rejection and preserves
  -- atomicity when the order is already preparing or ready.
  if exists (
    select 1
      from public.kitchen_ticket_items ti
     where ti.order_item_id = p_order_item_id
       and ti.status = 'completed'
  ) then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Completed kitchen work cannot be cancelled or removed'
    );
  end if;

  -- Removal is a soft cancellation so historical snapshots remain auditable.
  update public.order_items
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by_staff_id = v_actor_staff_id,
         cancellation_reason = v_reason
   where id = p_order_item_id;

  -- A preparing/ready order may now lose an item without regressing its order
  -- status. Scope the subtotal guard exception to this removal transaction.
  perform set_config(
    'restaurant_platform.order_allow_item_removal_subtotal',
    'on',
    true
  );

  perform private.recalculate_order_subtotal(v_item.order_id);

  perform set_config(
    'restaurant_platform.order_allow_item_removal_subtotal',
    'off',
    true
  );

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_order.branch_id,
    'order.item_removed', 'order_item', p_order_item_id, v_reason,
    jsonb_build_object(
      'order_id', v_item.order_id,
      'menu_item_id', v_item.menu_item_id
    )
  );

  return private.order_detail_json(v_item.order_id);
end;
$$;

comment on function public.remove_order_item(uuid, text) is
  'Soft-cancels an order item while the order is pending/accepted or while the order is preparing/ready and no matching kitchen item is completed. Rejects terminal orders and completed kitchen work.';

-- ---------------------------------------------------------------------------
-- 2. D8: enforce item -> ticket aggregate and cancelled-ticket invariants
-- ---------------------------------------------------------------------------

create or replace function private.kitchen_ticket_items_apply_aggregate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket_status public.kitchen_ticket_status;
begin
  if tg_op = 'UPDATE'
     and new.status is not distinct from old.status
  then
    return new;
  end if;

  -- Lock the parent ticket before checking its state. Item writes use the same
  -- item -> ticket lock order as the lifecycle RPCs and cancellation triggers.
  select t.status
    into v_ticket_status
    from public.kitchen_tickets t
   where t.id = new.ticket_id
   for update;

  if not found then
    return new;
  end if;

  -- A cancelled ticket is terminal. Only a cancelled ticket item may be
  -- inserted/left under it; active work must use a new generation.
  if v_ticket_status = 'cancelled' then
    if new.status <> 'cancelled' then
      perform private.raise_app_error(
        'KITCHEN_TICKET_CANCELLED',
        'A cancelled kitchen ticket cannot receive active items'
      );
    end if;

    return new;
  end if;

  -- Whole-order cancellation updates all ticket items and then cancels the
  -- tickets itself. Do not recalculate intermediate ticket aggregates in that
  -- path; the cancellation function owns the final ticket update and actor.
  if coalesce(
    current_setting(
      'restaurant_platform.kitchen_allow_completed_cancel',
      true
    ),
    'off'
  ) = 'on' then
    return new;
  end if;

  perform private.recalculate_kitchen_ticket_status(new.ticket_id);

  return new;
end;
$$;

revoke all on function private.kitchen_ticket_items_apply_aggregate() from public;

comment on function private.kitchen_ticket_items_apply_aggregate() is
  'Maintains the parent ticket aggregate for direct ticket-item writes and rejects active items under cancelled tickets. Whole-order cancellation owns its final ticket update.';

create trigger kitchen_ticket_items_apply_aggregate
  after insert or update of status on public.kitchen_ticket_items
  for each row execute function private.kitchen_ticket_items_apply_aggregate();

-- ---------------------------------------------------------------------------
-- 3. D9: cancellation attribution is immutable once recorded
-- ---------------------------------------------------------------------------

create or replace function private.guard_kitchen_cancellation_attribution_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'cancelled'
     and (
       new.cancelled_by_actor_type is distinct from old.cancelled_by_actor_type
       or new.cancelled_by_staff_id is distinct from old.cancelled_by_staff_id
       or new.cancelled_at is distinct from old.cancelled_at
       or new.cancellation_reason is distinct from old.cancellation_reason
     )
  then
    perform private.raise_app_error(
      'KITCHEN_CANCELLATION_INVALID',
      'Cancellation attribution is immutable once recorded'
    );
  end if;

  return new;
end;
$$;

revoke all on function private.guard_kitchen_cancellation_attribution_immutability() from public;

comment on function private.guard_kitchen_cancellation_attribution_immutability() is
  'Rejects changes to cancellation actor, timestamp, or reason after a kitchen ticket or ticket item is cancelled. First-time cancellation remains allowed.';

create trigger kitchen_tickets_guard_cancellation_attribution
  before update of
    cancelled_by_actor_type,
    cancelled_by_staff_id,
    cancelled_at,
    cancellation_reason
  on public.kitchen_tickets
  for each row execute function private.guard_kitchen_cancellation_attribution_immutability();

create trigger kitchen_ticket_items_guard_cancellation_attribution
  before update of
    cancelled_by_actor_type,
    cancelled_by_staff_id,
    cancelled_at,
    cancellation_reason
  on public.kitchen_ticket_items
  for each row execute function private.guard_kitchen_cancellation_attribution_immutability();
