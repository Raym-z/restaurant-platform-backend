-- M4.3: Order-state versus kitchen-state ownership policy.
--
-- POS/order operations own the order lifecycle. Kitchen Staff own kitchen
-- ticket and ticket-item preparation through the M4.2 kitchen RPCs. Kitchen
-- Staff must not use the order-level transition RPC to move an order to
-- preparing or ready while the KDS owns that operational signal.
--
-- This is the narrowest compatible change: only the role array for the
-- preparing/ready targets changes. All other order transitions, cascades,
-- locking, validation, and audit behavior are preserved exactly.
--
-- Design: docs/m3-core-pos-operations.md and docs/m4-kitchen-ticket-lifecycle.md.

create or replace function public.transition_order_status(
  p_order_id uuid,
  p_status public.order_status,
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
  v_order public.orders%rowtype;
  v_previous_status public.order_status;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select *
    into v_order
    from public.orders o
   where o.id = p_order_id;

  if not found or v_order.organization_id is distinct from v_org_id then
    perform private.raise_app_error('ORDER_NOT_FOUND', 'Order was not found');
  end if;

  if p_status = 'accepted' then
    perform authz.assert_branch_role(
      v_order.branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    );
  elsif p_status in ('preparing', 'ready') then
    -- M4.3: kitchen preparation state is owned by the KDS item/ticket RPCs.
    -- Kitchen Staff are intentionally excluded from the order-level preparing
    -- and ready transitions to prevent two conflicting controls.
    perform authz.assert_branch_role(
      v_order.branch_id,
      array['owner', 'admin', 'manager']::text[]
    );
  elsif p_status in ('served', 'completed') then
    perform authz.assert_branch_role(
      v_order.branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    );
  else
    perform private.raise_app_error(
      'ORDER_INVALID_STATUS',
      'Use cancel_order to cancel an order; other target statuses are not accepted here'
    );
  end if;

  if p_reason is not null and length(btrim(p_reason)) > 500 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Transition reason cannot exceed 500 characters');
  end if;

  select *
    into v_order
    from public.orders o
   where o.id = p_order_id
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

  if v_order.status = p_status then
    perform private.raise_app_error(
      'ORDER_INVALID_STATUS',
      'The order is already in the requested status'
    );
  end if;

  -- Keep non-cancelled item statuses aligned with the order-level lifecycle.
  -- Kitchen ticket-item preparation remains independent (M4.2).
  if p_status in ('accepted', 'preparing', 'ready', 'served') then
    update public.order_items
       set status = p_status::text::public.order_item_status,
           preparing_at = case
             when p_status = 'preparing' then coalesce(preparing_at, now())
             else preparing_at
           end,
           ready_at = case
             when p_status = 'ready' then coalesce(ready_at, now())
             else ready_at
           end,
           served_at = case
             when p_status = 'served' then coalesce(served_at, now())
             else served_at
           end
     where order_id = p_order_id
       and status <> 'cancelled';
  end if;

  v_previous_status := v_order.status;

  update public.orders
     set status = p_status
   where id = p_order_id
   returning * into v_order;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_order.branch_id,
    'order.status_changed', 'order', p_order_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object(
      'from_status', v_previous_status,
      'to_status', p_status
    )
  );

  return private.order_detail_json(p_order_id);
end;
$$;

revoke all on function public.transition_order_status(
  uuid,
  public.order_status,
  text
) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.transition_order_status(uuid, public.order_status, text) to authenticated';
  end if;
end
$$;

comment on function public.transition_order_status(
  uuid,
  public.order_status,
  text
) is
  'Applies the approved order state machine. M4.3: order-level preparing/ready requires Owner/Admin/Manager; Kitchen Staff use the kitchen ticket-item RPCs instead. Cancellation uses cancel_order.';
