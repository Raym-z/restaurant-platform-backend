-- M3 core POS operations: private read/pricing helpers.
--
-- These helpers are deliberately private. Public RPCs must authorize first and
-- then call them. Every helper uses an empty search_path and schema-qualified
-- references.

create or replace function private.order_summary_json(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'orderId', o.id,
    'orderReference', o.order_reference,
    'organizationId', o.organization_id,
    'branchId', o.branch_id,
    'diningSessionId', o.dining_session_id,
    'source', o.source,
    'status', o.status,
    'currency', o.currency_code,
    'subtotalMinor', o.subtotal_minor,
    'notes', o.notes,
    'itemCount', (
      select count(*)
      from public.order_items oi
      where oi.order_id = o.id
    ),
    'activeItemCount', (
      select count(*)
      from public.order_items oi
      where oi.order_id = o.id
        and oi.status <> 'cancelled'
    ),
    'createdAt', o.created_at,
    'updatedAt', o.updated_at,
    'acceptedAt', o.accepted_at,
    'preparingAt', o.preparing_at,
    'readyAt', o.ready_at,
    'servedAt', o.served_at,
    'completedAt', o.completed_at,
    'cancelledAt', o.cancelled_at,
    'cancellationReason', o.cancellation_reason
  )
  from public.orders o
  where o.id = p_order_id;
$$;

revoke all on function private.order_summary_json(uuid) from public;

create or replace function private.order_item_json(p_order_item_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'orderItemId', oi.id,
    'orderId', oi.order_id,
    'menuItemId', oi.menu_item_id,
    'name', oi.item_name_snapshot,
    'baseUnitPriceMinor', oi.base_unit_price_minor,
    'modifierUnitDeltaMinor', oi.modifier_unit_delta_minor,
    'effectiveUnitPriceMinor', oi.effective_unit_price_minor,
    'quantity', oi.quantity,
    'lineTotalMinor', oi.line_total_minor,
    'currency', oi.currency_code,
    'status', oi.status,
    'notes', oi.notes,
    'preparingAt', oi.preparing_at,
    'readyAt', oi.ready_at,
    'servedAt', oi.served_at,
    'cancelledAt', oi.cancelled_at,
    'cancellationReason', oi.cancellation_reason,
    'modifiers', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'modifierGroupId', m.modifier_group_id,
            'modifierOptionId', m.modifier_option_id,
            'groupName', m.group_name_snapshot,
            'optionName', m.option_name_snapshot,
            'priceDeltaMinor', m.price_delta_minor
          )
          order by m.group_name_snapshot, m.option_name_snapshot, m.id
        ),
        '[]'::jsonb
      )
      from public.order_item_modifiers m
      where m.order_item_id = oi.id
    )
  )
  from public.order_items oi
  where oi.id = p_order_item_id;
$$;

revoke all on function private.order_item_json(uuid) from public;

create or replace function private.order_detail_json(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.order_summary_json(o.id)
         || jsonb_build_object(
              'submittedByStaffId', o.submitted_by_staff_id,
              'cancelledByStaffId', o.cancelled_by_staff_id,
              'items', (
                select coalesce(
                  jsonb_agg(
                    private.order_item_json(oi.id)
                    order by oi.created_at, oi.id
                  ),
                  '[]'::jsonb
                )
                from public.order_items oi
                where oi.order_id = o.id
              )
            )
  from public.orders o
  where o.id = p_order_id;
$$;

revoke all on function private.order_detail_json(uuid) from public;

create or replace function private.table_summary_json(p_table_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'tableId', rt.id,
    'organizationId', rt.organization_id,
    'branchId', rt.branch_id,
    'label', rt.label,
    'capacity', rt.capacity,
    'status', rt.status,
    'deactivatedAt', rt.deactivated_at,
    'qrPublicId', (
      select tqr.public_id
      from public.table_qr_identifiers tqr
      where tqr.table_id = rt.id
        and tqr.revoked_at is null
      order by tqr.created_at desc, tqr.id desc
      limit 1
    ),
    'availability', case
      when rt.status = 'inactive' then 'inactive'
      when ds.id is not null then 'occupied'
      else 'available'
    end,
    'activeSessionId', ds.id,
    'activeSessionOpenedAt', ds.opened_at
  )
  from public.restaurant_tables rt
  left join public.dining_sessions ds
    on ds.table_id = rt.id
   and ds.status = 'active'
  where rt.id = p_table_id;
$$;

revoke all on function private.table_summary_json(uuid) from public;

create or replace function private.dining_session_summary_json(p_session_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'sessionId', ds.id,
    'organizationId', ds.organization_id,
    'branchId', ds.branch_id,
    'branchName', b.name,
    'tableId', ds.table_id,
    'tableLabel', rt.label,
    'status', ds.status,
    'openedAt', ds.opened_at,
    'closedAt', ds.closed_at,
    'openedByStaffId', ds.opened_by_staff_id,
    'closedByStaffId', ds.closed_by_staff_id,
    'currency', o.default_currency_code,
    'orderCount', (
      select count(*)
      from public.orders ord
      where ord.dining_session_id = ds.id
    ),
    'activeOrderCount', (
      select count(*)
      from public.orders ord
      where ord.dining_session_id = ds.id
        and ord.status in ('pending', 'accepted', 'preparing', 'ready', 'served')
    ),
    'subtotalMinor', (
      select coalesce(
        sum(ord.subtotal_minor) filter (where ord.status <> 'cancelled'),
        0
      )
      from public.orders ord
      where ord.dining_session_id = ds.id
    )
  )
  from public.dining_sessions ds
  join public.branches b
    on b.id = ds.branch_id
   and b.organization_id = ds.organization_id
  join public.restaurant_tables rt
    on rt.id = ds.table_id
   and rt.branch_id = ds.branch_id
   and rt.organization_id = ds.organization_id
  join public.organizations o
    on o.id = ds.organization_id
  where ds.id = p_session_id;
$$;

revoke all on function private.dining_session_summary_json(uuid) from public;

create or replace function private.dining_session_detail_json(p_session_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.dining_session_summary_json(ds.id)
         || jsonb_build_object(
              'orders', (
                select coalesce(
                  jsonb_agg(
                    private.order_summary_json(ord.id)
                    order by ord.created_at, ord.id
                  ),
                  '[]'::jsonb
                )
                from public.orders ord
                where ord.dining_session_id = ds.id
              )
            )
  from public.dining_sessions ds
  where ds.id = p_session_id;
$$;

revoke all on function private.dining_session_detail_json(uuid) from public;

create or replace function private.recalculate_order_subtotal(p_order_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subtotal bigint;
begin
  select coalesce(
           sum(oi.line_total_minor) filter (where oi.status <> 'cancelled'),
           0
         )
    into v_subtotal
    from public.order_items oi
   where oi.order_id = p_order_id;

  update public.orders
     set subtotal_minor = v_subtotal
   where id = p_order_id;

  return v_subtotal;
end;
$$;

revoke all on function private.recalculate_order_subtotal(uuid) from public;

-- Authoritative menu availability and pricing resolution for POS order writes.
--
-- Availability rule used by M3 (fail-closed where an explicit override exists):
--   * archived items/categories are unavailable;
--   * an explicit branch_menu_categories(false) row blocks the category;
--   * an explicit branch_menu_items(false) row blocks the item;
--   * otherwise the item is available at the branch.
--
-- Effective unit price = branch price override when present, else organization
-- base price. Client-submitted prices are never accepted.
create or replace function private.resolve_menu_item_for_branch(
  p_branch_id uuid,
  p_menu_item_id uuid,
  p_modifier_option_ids uuid[],
  p_quantity integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch_org_id uuid;
  v_item_id uuid;
  v_item_org_id uuid;
  v_category_id uuid;
  v_name text;
  v_base_price_minor bigint;
  v_price_override_minor bigint;
  v_currency_code text;
  v_org_currency_code text;
  v_item_archived_at timestamptz;
  v_category_archived_at timestamptz;
  v_branch_available boolean;
  v_option_ids uuid[];
  v_selected_count integer;
  v_modifier_delta_minor bigint;
  v_modifiers jsonb;
  v_effective_unit_price_minor bigint;
begin
  if p_quantity is null or p_quantity < 1 or p_quantity > 99 then
    perform private.raise_app_error(
      'ORDER_ITEM_QUANTITY_INVALID',
      'Item quantity must be between 1 and 99'
    );
  end if;

  select b.organization_id
    into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  select mi.id,
         mi.organization_id,
         mi.category_id,
         mi.name,
         mi.base_price_minor,
         mi.currency_code,
         mi.archived_at,
         mc.archived_at
    into v_item_id,
         v_item_org_id,
         v_category_id,
         v_name,
         v_base_price_minor,
         v_currency_code,
         v_item_archived_at,
         v_category_archived_at
    from public.menu_items mi
    join public.menu_categories mc
      on mc.id = mi.category_id
     and mc.organization_id = mi.organization_id
   where mi.id = p_menu_item_id;

  if v_item_id is null or v_item_org_id is distinct from v_branch_org_id then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_item_archived_at is not null or v_category_archived_at is not null then
    perform private.raise_app_error('MENU_ITEM_UNAVAILABLE', 'Menu item is not available');
  end if;

  select bmi.is_available, bmi.price_override_minor
    into v_branch_available, v_price_override_minor
    from public.branch_menu_items bmi
   where bmi.organization_id = v_branch_org_id
     and bmi.branch_id = p_branch_id
     and bmi.menu_item_id = p_menu_item_id;

  if coalesce(v_branch_available, true) = false then
    perform private.raise_app_error('MENU_ITEM_UNAVAILABLE', 'Menu item is not available at this branch');
  end if;

  if exists (
    select 1
    from public.branch_menu_categories bmc
    where bmc.organization_id = v_branch_org_id
      and bmc.branch_id = p_branch_id
      and bmc.menu_category_id = v_category_id
      and bmc.is_available = false
  ) then
    perform private.raise_app_error('MENU_ITEM_UNAVAILABLE', 'Menu category is not available at this branch');
  end if;

  select o.default_currency_code
    into v_org_currency_code
    from public.organizations o
   where o.id = v_branch_org_id;

  if v_currency_code is distinct from v_org_currency_code then
    perform private.raise_app_error('MENU_ITEM_UNAVAILABLE', 'Menu item currency is inconsistent');
  end if;

  v_option_ids := coalesce(p_modifier_option_ids, '{}'::uuid[]);

  if coalesce(array_length(v_option_ids, 1), 0) > 50 then
    perform private.raise_app_error(
      'INVALID_MODIFIER_SELECTION',
      'Too many modifier options were selected'
    );
  end if;

  if coalesce(array_length(v_option_ids, 1), 0) <> (
    select count(distinct option_id)::integer
    from unnest(v_option_ids) as options(option_id)
  ) then
    perform private.raise_app_error(
      'INVALID_MODIFIER_SELECTION',
      'Duplicate modifier options are not permitted'
    );
  end if;

  select count(*)::integer
    into v_selected_count
    from public.modifier_options mo
    join public.modifier_groups mg
      on mg.id = mo.modifier_group_id
     and mg.organization_id = mo.organization_id
    join public.menu_item_modifier_groups mimg
      on mimg.modifier_group_id = mg.id
     and mimg.menu_item_id = v_item_id
     and mimg.organization_id = v_item_org_id
   where mo.organization_id = v_item_org_id
     and mo.id = any(v_option_ids)
     and mo.archived_at is null
     and mg.archived_at is null;

  if v_selected_count <> coalesce(array_length(v_option_ids, 1), 0) then
    perform private.raise_app_error(
      'INVALID_MODIFIER_SELECTION',
      'One or more modifier options are invalid for this item'
    );
  end if;

  if exists (
    select 1
    from public.menu_item_modifier_groups mimg
    join public.modifier_groups mg
      on mg.id = mimg.modifier_group_id
     and mg.organization_id = mimg.organization_id
    left join public.modifier_options mo
      on mo.modifier_group_id = mg.id
     and mo.organization_id = mg.organization_id
     and mo.id = any(v_option_ids)
     and mo.archived_at is null
    where mimg.menu_item_id = v_item_id
      and mimg.organization_id = v_item_org_id
      and mg.archived_at is null
    group by mg.id, mg.min_selections, mg.max_selections
    having count(mo.id) < mg.min_selections
        or count(mo.id) > mg.max_selections
  ) then
    perform private.raise_app_error(
      'INVALID_MODIFIER_SELECTION',
      'Modifier selections do not satisfy the group limits'
    );
  end if;

  select coalesce(sum(mo.price_delta_minor), 0),
         coalesce(
           jsonb_agg(
             jsonb_build_object(
               'modifierGroupId', mg.id,
               'modifierOptionId', mo.id,
               'groupName', mg.name,
               'optionName', mo.name,
               'priceDeltaMinor', mo.price_delta_minor
             )
             order by mg.sort_order, mo.sort_order, mo.id
           ),
           '[]'::jsonb
         )
    into v_modifier_delta_minor, v_modifiers
    from public.modifier_options mo
    join public.modifier_groups mg
      on mg.id = mo.modifier_group_id
     and mg.organization_id = mo.organization_id
   where mo.organization_id = v_item_org_id
     and mo.id = any(v_option_ids)
     and mo.archived_at is null
     and mg.archived_at is null;

  v_effective_unit_price_minor :=
    coalesce(v_price_override_minor, v_base_price_minor)
    + coalesce(v_modifier_delta_minor, 0);

  if v_effective_unit_price_minor < 0 then
    perform private.raise_app_error(
      'INVALID_MENU_PRICE',
      'The effective item price cannot be negative'
    );
  end if;

  return jsonb_build_object(
    'menuItemId', v_item_id,
    'name', v_name,
    'baseUnitPriceMinor', coalesce(v_price_override_minor, v_base_price_minor),
    'modifierUnitDeltaMinor', coalesce(v_modifier_delta_minor, 0),
    'effectiveUnitPriceMinor', v_effective_unit_price_minor,
    'lineTotalMinor', v_effective_unit_price_minor * p_quantity,
    'currency', v_currency_code,
    'modifiers', v_modifiers
  );
end;
$$;

revoke all on function private.resolve_menu_item_for_branch(uuid, uuid, uuid[], integer) from public;

comment on function private.resolve_menu_item_for_branch(uuid, uuid, uuid[], integer) is
  'Resolves branch availability, effective price, and modifier snapshots from authoritative database state.';
