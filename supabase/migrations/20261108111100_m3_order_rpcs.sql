-- M3 core POS operations: transactional order RPCs.
--
-- All prices, totals, availability, and modifier deltas are resolved from the
-- database. Client-submitted prices are not part of any request.

create or replace function public.create_order(
  p_dining_session_id uuid,
  p_items jsonb,
  p_notes text default null,
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
  v_session public.dining_sessions%rowtype;
  v_session_status public.dining_session_status;
  v_currency_code text;
  v_notes text;
  v_idem jsonb;
  v_response jsonb;
  v_fingerprint text;
  v_item jsonb;
  v_option jsonb;
  v_option_text text;
  v_option_ids uuid[];
  v_menu_item_id uuid;
  v_quantity integer;
  v_line jsonb;
  v_modifier jsonb;
  v_order_id uuid;
  v_order_reference text;
  v_order_item_id uuid;
  v_item_count integer;
  v_subtotal bigint;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select *
    into v_session
    from public.dining_sessions ds
   where ds.id = p_dining_session_id;

  if not found or v_session.organization_id is distinct from v_org_id then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  perform authz.assert_branch_role(
    v_session.branch_id,
    array['owner', 'admin', 'manager', 'cashier']::text[]
  );

  v_notes := nullif(btrim(p_notes), '');

  if v_notes is not null and length(v_notes) > 1000 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Order notes cannot exceed 1000 characters');
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    perform private.raise_app_error('ORDER_EMPTY', 'An order must contain at least one item');
  end if;

  if jsonb_array_length(p_items) = 0 then
    perform private.raise_app_error('ORDER_EMPTY', 'An order must contain at least one item');
  end if;

  if jsonb_array_length(p_items) > 100 then
    perform private.raise_app_error('VALIDATION_ERROR', 'An order cannot contain more than 100 lines');
  end if;

  v_fingerprint := private.sha256_hex(
    concat_ws(
      '|',
      'order.create',
      p_dining_session_id::text,
      coalesce(v_notes, ''),
      p_items::text
    )
  );

  if p_idempotency_key is not null then
    v_idem := private.idempotency_begin(
      'staff',
      v_actor_staff_id,
      'order.create',
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

  -- Share-lock the session so opening an order cannot race session closure.
  select ds.status
    into v_session_status
    from public.dining_sessions ds
   where ds.id = p_dining_session_id
   for share;

  if v_session_status is null then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  if v_session_status <> 'active' then
    perform private.raise_app_error('SESSION_NOT_ACTIVE', 'The dining session is not active');
  end if;

  select o.default_currency_code
    into v_currency_code
    from public.organizations o
   where o.id = v_org_id;

  insert into public.orders (
    organization_id,
    branch_id,
    dining_session_id,
    source,
    status,
    currency_code,
    subtotal_minor,
    notes,
    submitted_by_staff_id
  )
  values (
    v_org_id,
    v_session.branch_id,
    p_dining_session_id,
    'staff',
    'pending',
    v_currency_code,
    0,
    v_notes,
    v_actor_staff_id
  )
  returning id, order_reference
  into v_order_id, v_order_reference;

  v_item_count := 0;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      perform private.raise_app_error('VALIDATION_ERROR', 'Every order line must be an object');
    end if;

    if exists (
      select 1
      from jsonb_object_keys(v_item) as line_keys(line_key)
      where line_key not in ('menuItemId', 'quantity', 'modifierOptionIds', 'notes')
    ) then
      perform private.raise_app_error('VALIDATION_ERROR', 'Order line contains an unsupported field');
    end if;

    if jsonb_typeof(v_item -> 'menuItemId') is distinct from 'string'
       or (v_item ->> 'menuItemId') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    then
      perform private.raise_app_error('VALIDATION_ERROR', 'Every order line requires a valid menuItemId');
    end if;

    v_menu_item_id := (v_item ->> 'menuItemId')::uuid;

    if jsonb_typeof(v_item -> 'quantity') is distinct from 'number'
       or (v_item ->> 'quantity') !~ '^[0-9]{1,2}$'
    then
      perform private.raise_app_error(
        'ORDER_ITEM_QUANTITY_INVALID',
        'Item quantity must be an integer between 1 and 99'
      );
    end if;

    v_quantity := (v_item ->> 'quantity')::integer;

    if v_quantity < 1 or v_quantity > 99 then
      perform private.raise_app_error(
        'ORDER_ITEM_QUANTITY_INVALID',
        'Item quantity must be between 1 and 99'
      );
    end if;

    v_option_ids := '{}'::uuid[];

    if v_item ? 'modifierOptionIds'
       and jsonb_typeof(v_item -> 'modifierOptionIds') <> 'null'
    then
      if jsonb_typeof(v_item -> 'modifierOptionIds') <> 'array' then
        perform private.raise_app_error(
          'INVALID_MODIFIER_SELECTION',
          'modifierOptionIds must be an array'
        );
      end if;

      if jsonb_array_length(v_item -> 'modifierOptionIds') > 50 then
        perform private.raise_app_error(
          'INVALID_MODIFIER_SELECTION',
          'Too many modifier options were selected'
        );
      end if;

      for v_option in select value from jsonb_array_elements(v_item -> 'modifierOptionIds')
      loop
        if jsonb_typeof(v_option) <> 'string' then
          perform private.raise_app_error(
            'INVALID_MODIFIER_SELECTION',
            'Modifier option identifiers must be strings'
          );
        end if;

        v_option_text := v_option #>> '{}';

        if v_option_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
          perform private.raise_app_error(
            'INVALID_MODIFIER_SELECTION',
            'Modifier option identifiers must be UUIDs'
          );
        end if;

        v_option_ids := array_append(v_option_ids, v_option_text::uuid);
      end loop;
    end if;

    if v_item ? 'notes'
       and jsonb_typeof(v_item -> 'notes') <> 'null'
    then
      if jsonb_typeof(v_item -> 'notes') <> 'string'
         or length(v_item ->> 'notes') > 500
      then
        perform private.raise_app_error(
          'VALIDATION_ERROR',
          'Order line notes must be a string of at most 500 characters'
        );
      end if;
    end if;

    v_line := private.resolve_menu_item_for_branch(
      v_session.branch_id,
      v_menu_item_id,
      v_option_ids,
      v_quantity
    );

    insert into public.order_items (
      order_id,
      organization_id,
      branch_id,
      menu_item_id,
      item_name_snapshot,
      base_unit_price_minor,
      modifier_unit_delta_minor,
      quantity,
      currency_code,
      status,
      notes
    )
    values (
      v_order_id,
      v_org_id,
      v_session.branch_id,
      v_menu_item_id,
      v_line ->> 'name',
      (v_line ->> 'baseUnitPriceMinor')::bigint,
      (v_line ->> 'modifierUnitDeltaMinor')::bigint,
      v_quantity,
      v_line ->> 'currency',
      'pending',
      nullif(btrim(v_item ->> 'notes'), '')
    )
    returning id into v_order_item_id;

    for v_modifier in select value from jsonb_array_elements(v_line -> 'modifiers')
    loop
      insert into public.order_item_modifiers (
        order_item_id,
        organization_id,
        modifier_group_id,
        modifier_option_id,
        group_name_snapshot,
        option_name_snapshot,
        price_delta_minor
      )
      values (
        v_order_item_id,
        v_org_id,
        (v_modifier ->> 'modifierGroupId')::uuid,
        (v_modifier ->> 'modifierOptionId')::uuid,
        v_modifier ->> 'groupName',
        v_modifier ->> 'optionName',
        (v_modifier ->> 'priceDeltaMinor')::bigint
      );
    end loop;

    v_item_count := v_item_count + 1;
  end loop;

  v_subtotal := private.recalculate_order_subtotal(v_order_id);

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_session.branch_id,
    'order.created', 'order', v_order_id, null,
    jsonb_build_object(
      'order_reference', v_order_reference,
      'dining_session_id', p_dining_session_id,
      'item_count', v_item_count,
      'subtotal_minor', v_subtotal
    )
  );

  v_response := private.order_detail_json(v_order_id);

  if p_idempotency_key is not null then
    perform private.idempotency_complete((v_idem ->> 'id')::uuid, v_response);
  end if;

  return v_response;
end;
$$;

create or replace function public.get_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_order_org_id uuid;
  v_branch_id uuid;
  v_order jsonb;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select o.organization_id, o.branch_id
    into v_order_org_id, v_branch_id
    from public.orders o
   where o.id = p_order_id;

  if v_order_org_id is null or v_order_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORDER_NOT_FOUND', 'Order was not found');
  end if;

  perform private.assert_branch_history_access(v_branch_id);

  v_order := private.order_detail_json(p_order_id);

  if v_order is null then
    perform private.raise_app_error('ORDER_NOT_FOUND', 'Order was not found');
  end if;

  return v_order;
end;
$$;

create or replace function public.list_orders_by_session(
  p_dining_session_id uuid,
  p_status public.order_status default null,
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
  v_session_org_id uuid;
  v_branch_id uuid;
  v_orders jsonb;
  v_has_more boolean;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select ds.organization_id, ds.branch_id
    into v_session_org_id, v_branch_id
    from public.dining_sessions ds
   where ds.id = p_dining_session_id;

  if v_session_org_id is null or v_session_org_id is distinct from v_org_id then
    perform private.raise_app_error('DINING_SESSION_NOT_FOUND', 'Dining session was not found');
  end if;

  perform private.assert_branch_history_access(v_branch_id);

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Page size must be between 1 and 100');
  end if;

  if p_offset is null or p_offset < 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Offset cannot be negative');
  end if;

  with page as (
    select o.id, o.created_at
    from public.orders o
    where o.organization_id = v_org_id
      and o.dining_session_id = p_dining_session_id
      and (p_status is null or o.status = p_status)
    order by o.created_at asc, o.id asc
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
             private.order_summary_json(n.id)
             order by n.created_at asc, n.id asc
           ) filter (where n.rn <= p_limit),
           '[]'::jsonb
         ),
         (select count(*) from numbered) > p_limit
    into v_orders, v_has_more
    from numbered n;

  return jsonb_build_object(
    'diningSessionId', p_dining_session_id,
    'orders', v_orders,
    'pageSize', p_limit,
    'hasMore', v_has_more,
    'nextOffset', case when v_has_more then p_offset + p_limit else null end
  );
end;
$$;

create or replace function public.list_branch_orders(
  p_branch_id uuid,
  p_status public.order_status default null,
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
  v_orders jsonb;
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

  perform private.assert_branch_history_access(p_branch_id);

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
    select o.id, o.created_at
    from public.orders o
    where o.organization_id = v_org_id
      and o.branch_id = p_branch_id
      and (p_status is null or o.status = p_status)
      and (p_from is null or o.created_at >= p_from)
      and (p_to is null or o.created_at < p_to)
    order by o.created_at desc, o.id desc
    limit p_limit + 1
    offset p_offset
  ),
  numbered as (
    select p.id,
           p.created_at,
           row_number() over (order by p.created_at desc, p.id desc) as rn
    from page p
  )
  select coalesce(
           jsonb_agg(
             private.order_summary_json(n.id)
             order by n.created_at desc, n.id desc
           ) filter (where n.rn <= p_limit),
           '[]'::jsonb
         ),
         (select count(*) from numbered) > p_limit
    into v_orders, v_has_more
    from numbered n;

  return jsonb_build_object(
    'branchId', p_branch_id,
    'orders', v_orders,
    'pageSize', p_limit,
    'hasMore', v_has_more,
    'nextOffset', case when v_has_more then p_offset + p_limit else null end
  );
end;
$$;

create or replace function public.add_order_item(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_quantity integer,
  p_modifier_option_ids uuid[] default '{}'::uuid[],
  p_notes text default null
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
  v_line jsonb;
  v_modifier jsonb;
  v_order_item_id uuid;
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

  perform authz.assert_branch_role(
    v_order.branch_id,
    array['owner', 'admin', 'manager', 'cashier']::text[]
  );

  -- Adding a new billable line is new operational work. Existing orders remain
  -- editable for reductions/removals and can still be completed or cancelled
  -- while the organization is restricted or suspended.
  perform authz.assert_org_operational(v_org_id);

  if p_quantity is null or p_quantity < 1 or p_quantity > 99 then
    perform private.raise_app_error(
      'ORDER_ITEM_QUANTITY_INVALID',
      'Item quantity must be between 1 and 99'
    );
  end if;

  if p_notes is not null and length(btrim(p_notes)) > 500 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Item notes cannot exceed 500 characters');
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

  if v_order.status not in ('pending', 'accepted') then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Items cannot be added after kitchen preparation has started'
    );
  end if;

  v_line := private.resolve_menu_item_for_branch(
    v_order.branch_id,
    p_menu_item_id,
    coalesce(p_modifier_option_ids, '{}'::uuid[]),
    p_quantity
  );

  insert into public.order_items (
    order_id,
    organization_id,
    branch_id,
    menu_item_id,
    item_name_snapshot,
    base_unit_price_minor,
    modifier_unit_delta_minor,
    quantity,
    currency_code,
    status,
    notes
  )
  values (
    p_order_id,
    v_org_id,
    v_order.branch_id,
    p_menu_item_id,
    v_line ->> 'name',
    (v_line ->> 'baseUnitPriceMinor')::bigint,
    (v_line ->> 'modifierUnitDeltaMinor')::bigint,
    p_quantity,
    v_line ->> 'currency',
    v_order.status::text::public.order_item_status,
    nullif(btrim(p_notes), '')
  )
  returning id into v_order_item_id;

  for v_modifier in select value from jsonb_array_elements(v_line -> 'modifiers')
  loop
    insert into public.order_item_modifiers (
      order_item_id,
      organization_id,
      modifier_group_id,
      modifier_option_id,
      group_name_snapshot,
      option_name_snapshot,
      price_delta_minor
    )
    values (
      v_order_item_id,
      v_org_id,
      (v_modifier ->> 'modifierGroupId')::uuid,
      (v_modifier ->> 'modifierOptionId')::uuid,
      v_modifier ->> 'groupName',
      v_modifier ->> 'optionName',
      (v_modifier ->> 'priceDeltaMinor')::bigint
    );
  end loop;

  perform private.recalculate_order_subtotal(p_order_id);

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_order.branch_id,
    'order.item_added', 'order', p_order_id, null,
    jsonb_build_object(
      'order_item_id', v_order_item_id,
      'menu_item_id', p_menu_item_id,
      'quantity', p_quantity
    )
  );

  return private.order_detail_json(p_order_id);
end;
$$;

create or replace function public.update_order_item_quantity(
  p_order_item_id uuid,
  p_quantity integer
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
  v_old_quantity integer;
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

  if p_quantity is null or p_quantity < 1 or p_quantity > 99 then
    perform private.raise_app_error(
      'ORDER_ITEM_QUANTITY_INVALID',
      'Item quantity must be between 1 and 99'
    );
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

  if v_order.status not in ('pending', 'accepted') then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Item quantity cannot be changed after kitchen preparation has started'
    );
  end if;

  if v_item.status = 'cancelled' then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'A cancelled order item cannot be modified'
    );
  end if;

  v_old_quantity := v_item.quantity;

  -- Increasing billable quantity is new operational work. Reducing quantity is
  -- a correction and remains available during a restriction or suspension.
  if p_quantity > v_old_quantity then
    perform authz.assert_org_operational(v_org_id);
  end if;

  update public.order_items
     set quantity = p_quantity
   where id = p_order_item_id;

  perform private.recalculate_order_subtotal(v_item.order_id);

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_order.branch_id,
    'order.item_quantity_updated', 'order_item', p_order_item_id, null,
    jsonb_build_object(
      'order_id', v_item.order_id,
      'old_quantity', v_old_quantity,
      'new_quantity', p_quantity
    )
  );

  return private.order_detail_json(v_item.order_id);
end;
$$;

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

  if v_order.status not in ('pending', 'accepted') then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'Items cannot be removed after kitchen preparation has started'
    );
  end if;

  if v_item.status = 'cancelled' then
    perform private.raise_app_error(
      'ORDER_MODIFICATION_NOT_ALLOWED',
      'The order item is already cancelled'
    );
  end if;

  -- Removal is a soft cancellation so historical snapshots remain auditable.
  update public.order_items
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by_staff_id = v_actor_staff_id,
         cancellation_reason = v_reason
   where id = p_order_item_id;

  perform private.recalculate_order_subtotal(v_item.order_id);

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
    perform authz.assert_branch_role(
      v_order.branch_id,
      array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
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
  -- Item-level independent transitions remain a later KDS concern.
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

create or replace function public.cancel_order(
  p_order_id uuid,
  p_reason text
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
  v_reason text;
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

  perform authz.assert_branch_role(
    v_order.branch_id,
    array['owner', 'admin', 'manager', 'cashier']::text[]
  );

  v_reason := nullif(btrim(p_reason), '');

  if v_reason is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'A cancellation reason is required');
  end if;

  if length(v_reason) > 500 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Cancellation reason cannot exceed 500 characters');
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

  if v_order.status not in ('pending', 'accepted', 'preparing', 'ready') then
    perform private.raise_app_error(
      'ORDER_INVALID_STATUS',
      'The order cannot be cancelled in its current status'
    );
  end if;

  v_previous_status := v_order.status;

  update public.orders
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by_staff_id = v_actor_staff_id,
         cancellation_reason = v_reason
   where id = p_order_id;

  update public.order_items
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by_staff_id = v_actor_staff_id,
         cancellation_reason = v_reason
   where order_id = p_order_id
     and status <> 'cancelled';

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_order.branch_id,
    'order.cancelled', 'order', p_order_id, v_reason,
    jsonb_build_object('previous_status', v_previous_status)
  );

  return private.order_detail_json(p_order_id);
end;
$$;

revoke all on function public.create_order(uuid, jsonb, text, text) from public;
revoke all on function public.get_order(uuid) from public;
revoke all on function public.list_orders_by_session(
  uuid, public.order_status, integer, integer
) from public;
revoke all on function public.list_branch_orders(
  uuid, public.order_status, timestamptz, timestamptz, integer, integer
) from public;
revoke all on function public.add_order_item(uuid, uuid, integer, uuid[], text) from public;
revoke all on function public.update_order_item_quantity(uuid, integer) from public;
revoke all on function public.remove_order_item(uuid, text) from public;
revoke all on function public.transition_order_status(uuid, public.order_status, text) from public;
revoke all on function public.cancel_order(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_order(uuid, jsonb, text, text) to authenticated';
    execute 'grant execute on function public.get_order(uuid) to authenticated';
    execute 'grant execute on function public.list_orders_by_session(uuid, public.order_status, integer, integer) to authenticated';
    execute 'grant execute on function public.list_branch_orders(uuid, public.order_status, timestamptz, timestamptz, integer, integer) to authenticated';
    execute 'grant execute on function public.add_order_item(uuid, uuid, integer, uuid[], text) to authenticated';
    execute 'grant execute on function public.update_order_item_quantity(uuid, integer) to authenticated';
    execute 'grant execute on function public.remove_order_item(uuid, text) to authenticated';
    execute 'grant execute on function public.transition_order_status(uuid, public.order_status, text) to authenticated';
    execute 'grant execute on function public.cancel_order(uuid, text) to authenticated';
  end if;
end
$$;

comment on function public.create_order(uuid, jsonb, text, text) is
  'Creates a staff order from authoritative branch pricing and snapshots. Idempotent when a key is supplied.';

comment on function public.transition_order_status(uuid, public.order_status, text) is
  'Applies the approved order state machine. Cancellation uses cancel_order.';

comment on function public.remove_order_item(uuid, text) is
  'Soft-cancels an order item before preparation so historical snapshots remain auditable.';
