-- Menu, table, QR, dining-session, and guest-token RPCs.

create or replace function public.create_menu_category(
  p_name text,
  p_description text default null,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_category_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();
  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Category name is required');
  end if;

  insert into public.menu_categories (organization_id, name, description, sort_order)
  values (v_org_id, btrim(p_name), nullif(btrim(p_description), ''), p_sort_order)
  returning id into v_category_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.category_created', 'menu_category', v_category_id, null,
    jsonb_build_object('name', btrim(p_name))
  );

  return jsonb_build_object('categoryId', v_category_id);
end;
$$;

create or replace function public.update_menu_category(
  p_category_id uuid,
  p_name text,
  p_description text default null,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_category_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mc.organization_id into v_category_org_id
    from public.menu_categories mc
   where mc.id = p_category_id;

  if v_category_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu category was not found');
  end if;

  if v_category_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu category belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  update public.menu_categories
     set name = btrim(p_name),
         description = nullif(btrim(p_description), ''),
         sort_order = p_sort_order
   where id = p_category_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.category_updated', 'menu_category', p_category_id, null,
    jsonb_build_object('name', btrim(p_name))
  );

  return jsonb_build_object('categoryId', p_category_id);
end;
$$;

create or replace function public.archive_menu_category(p_category_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_category_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mc.organization_id into v_category_org_id
    from public.menu_categories mc
   where mc.id = p_category_id;

  if v_category_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu category was not found');
  end if;

  if v_category_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu category belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);

  update public.menu_categories
     set archived_at = now()
   where id = p_category_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.category_archived', 'menu_category', p_category_id, null, '{}'::jsonb
  );

  return jsonb_build_object('categoryId', p_category_id, 'archived', true);
end;
$$;

create or replace function public.create_menu_item(
  p_category_id uuid,
  p_name text,
  p_base_price_minor bigint,
  p_description text default null,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_category_org_id uuid;
  v_currency_code text;
  v_item_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mc.organization_id into v_category_org_id
    from public.menu_categories mc
   where mc.id = p_category_id;

  if v_category_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu category was not found');
  end if;

  if v_category_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu category belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Item name is required');
  end if;

  if p_base_price_minor < 0 then
    perform private.raise_app_error('INVALID_MENU_PRICE', 'Menu price cannot be negative');
  end if;

  select o.default_currency_code into v_currency_code
    from public.organizations o
   where o.id = v_org_id;

  insert into public.menu_items (
    organization_id,
    category_id,
    name,
    description,
    base_price_minor,
    currency_code,
    sort_order
  )
  values (
    v_org_id,
    p_category_id,
    btrim(p_name),
    nullif(btrim(p_description), ''),
    p_base_price_minor,
    v_currency_code,
    p_sort_order
  )
  returning id into v_item_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.item_created', 'menu_item', v_item_id, null,
    jsonb_build_object('name', btrim(p_name), 'base_price_minor', p_base_price_minor)
  );

  return jsonb_build_object('menuItemId', v_item_id);
end;
$$;

create or replace function public.update_menu_item(
  p_menu_item_id uuid,
  p_name text,
  p_base_price_minor bigint,
  p_description text default null,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_item_org_id uuid;
  v_old_price bigint;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mi.organization_id, mi.base_price_minor
    into v_item_org_id, v_old_price
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_item_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu item belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if p_base_price_minor < 0 then
    perform private.raise_app_error('INVALID_MENU_PRICE', 'Menu price cannot be negative');
  end if;

  update public.menu_items
     set name = btrim(p_name),
         description = nullif(btrim(p_description), ''),
         base_price_minor = p_base_price_minor,
         sort_order = p_sort_order
   where id = p_menu_item_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.item_updated', 'menu_item', p_menu_item_id, null,
    jsonb_build_object(
      'name', btrim(p_name),
      'old_base_price_minor', v_old_price,
      'new_base_price_minor', p_base_price_minor
    )
  );

  return jsonb_build_object('menuItemId', p_menu_item_id);
end;
$$;

create or replace function public.update_base_item_price(
  p_menu_item_id uuid,
  p_base_price_minor bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_item_org_id uuid;
  v_old_price bigint;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mi.organization_id, mi.base_price_minor
    into v_item_org_id, v_old_price
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_item_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu item belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if p_base_price_minor < 0 then
    perform private.raise_app_error('INVALID_MENU_PRICE', 'Menu price cannot be negative');
  end if;

  update public.menu_items
     set base_price_minor = p_base_price_minor
   where id = p_menu_item_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.base_price_updated', 'menu_item', p_menu_item_id, null,
    jsonb_build_object(
      'old_base_price_minor', v_old_price,
      'new_base_price_minor', p_base_price_minor
    )
  );

  return jsonb_build_object('menuItemId', p_menu_item_id, 'basePriceMinor', p_base_price_minor);
end;
$$;

create or replace function public.archive_menu_item(p_menu_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_item_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mi.organization_id into v_item_org_id
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_item_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu item belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);

  update public.menu_items
     set archived_at = now()
   where id = p_menu_item_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.item_archived', 'menu_item', p_menu_item_id, null, '{}'::jsonb
  );

  return jsonb_build_object('menuItemId', p_menu_item_id, 'archived', true);
end;
$$;

create or replace function public.create_modifier_group(
  p_name text,
  p_description text default null,
  p_min_selections integer default 0,
  p_max_selections integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_group_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();
  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Modifier group name is required');
  end if;

  insert into public.modifier_groups (
    organization_id, name, description, min_selections, max_selections
  )
  values (
    v_org_id, btrim(p_name), nullif(btrim(p_description), ''), p_min_selections, p_max_selections
  )
  returning id into v_group_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.modifier_group_created', 'modifier_group', v_group_id, null,
    jsonb_build_object('name', btrim(p_name))
  );

  return jsonb_build_object('modifierGroupId', v_group_id);
end;
$$;

create or replace function public.update_modifier_group(
  p_modifier_group_id uuid,
  p_name text,
  p_description text default null,
  p_min_selections integer default 0,
  p_max_selections integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_group_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mg.organization_id into v_group_org_id
    from public.modifier_groups mg
   where mg.id = p_modifier_group_id;

  if v_group_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Modifier group was not found');
  end if;

  if v_group_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Modifier group belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  update public.modifier_groups
     set name = btrim(p_name),
         description = nullif(btrim(p_description), ''),
         min_selections = p_min_selections,
         max_selections = p_max_selections
   where id = p_modifier_group_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.modifier_group_updated', 'modifier_group', p_modifier_group_id, null,
    jsonb_build_object('name', btrim(p_name))
  );

  return jsonb_build_object('modifierGroupId', p_modifier_group_id);
end;
$$;

create or replace function public.create_modifier_option(
  p_modifier_group_id uuid,
  p_name text,
  p_price_delta_minor bigint default 0,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_group_org_id uuid;
  v_option_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mg.organization_id into v_group_org_id
    from public.modifier_groups mg
   where mg.id = p_modifier_group_id;

  if v_group_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Modifier group was not found');
  end if;

  if v_group_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Modifier group belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Modifier option name is required');
  end if;

  insert into public.modifier_options (
    organization_id, modifier_group_id, name, price_delta_minor, sort_order
  )
  values (
    v_org_id, p_modifier_group_id, btrim(p_name), p_price_delta_minor, p_sort_order
  )
  returning id into v_option_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.modifier_option_created', 'modifier_option', v_option_id, null,
    jsonb_build_object('name', btrim(p_name), 'price_delta_minor', p_price_delta_minor)
  );

  return jsonb_build_object('modifierOptionId', v_option_id);
end;
$$;

create or replace function public.update_modifier_option(
  p_modifier_option_id uuid,
  p_name text,
  p_price_delta_minor bigint default 0,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_option_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mo.organization_id into v_option_org_id
    from public.modifier_options mo
   where mo.id = p_modifier_option_id;

  if v_option_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Modifier option was not found');
  end if;

  if v_option_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Modifier option belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  update public.modifier_options
     set name = btrim(p_name),
         price_delta_minor = p_price_delta_minor,
         sort_order = p_sort_order
   where id = p_modifier_option_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.modifier_option_updated', 'modifier_option', p_modifier_option_id, null,
    jsonb_build_object('name', btrim(p_name), 'price_delta_minor', p_price_delta_minor)
  );

  return jsonb_build_object('modifierOptionId', p_modifier_option_id);
end;
$$;

create or replace function public.assign_modifier_group(
  p_menu_item_id uuid,
  p_modifier_group_id uuid,
  p_sort_order integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_item_org_id uuid;
  v_group_org_id uuid;
  v_link_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select mi.organization_id into v_item_org_id
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  select mg.organization_id into v_group_org_id
    from public.modifier_groups mg
   where mg.id = p_modifier_group_id;

  if v_item_org_id is null or v_group_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item or modifier group was not found');
  end if;

  if v_item_org_id is distinct from v_org_id
     or v_group_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Menu item or modifier group belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);

  begin
    insert into public.menu_item_modifier_groups (
      organization_id, menu_item_id, modifier_group_id, sort_order
    )
    values (v_org_id, p_menu_item_id, p_modifier_group_id, p_sort_order)
    returning id into v_link_id;
  exception
    when unique_violation then
      perform private.raise_app_error('RESOURCE_CONFLICT', 'Modifier group is already assigned to this item');
  end;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, null,
    'menu.modifier_group_assigned', 'menu_item', p_menu_item_id, null,
    jsonb_build_object('modifier_group_id', p_modifier_group_id)
  );

  return jsonb_build_object('linkId', v_link_id);
end;
$$;

create or replace function public.set_branch_item_availability(
  p_branch_id uuid,
  p_menu_item_id uuid,
  p_is_available boolean
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
  v_item_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  select mi.organization_id into v_item_org_id
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Branch or menu item belongs to another organization');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  insert into public.branch_menu_items (
    organization_id, branch_id, menu_item_id, is_available
  )
  values (v_org_id, p_branch_id, p_menu_item_id, p_is_available)
  on conflict (branch_id, menu_item_id)
  do update set is_available = excluded.is_available;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'menu.branch_availability_updated', 'menu_item', p_menu_item_id, null,
    jsonb_build_object('is_available', p_is_available)
  );

  return jsonb_build_object(
    'branchId', p_branch_id,
    'menuItemId', p_menu_item_id,
    'isAvailable', p_is_available
  );
end;
$$;

create or replace function public.set_branch_price_override(
  p_branch_id uuid,
  p_menu_item_id uuid,
  p_price_minor bigint
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
  v_item_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  select mi.organization_id into v_item_org_id
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Branch or menu item belongs to another organization');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if p_price_minor < 0 then
    perform private.raise_app_error('INVALID_MENU_PRICE', 'Menu price cannot be negative');
  end if;

  insert into public.branch_menu_items (
    organization_id, branch_id, menu_item_id, is_available, price_override_minor
  )
  values (v_org_id, p_branch_id, p_menu_item_id, true, p_price_minor)
  on conflict (branch_id, menu_item_id)
  do update set price_override_minor = excluded.price_override_minor;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'menu.branch_price_override_set', 'menu_item', p_menu_item_id, null,
    jsonb_build_object('price_override_minor', p_price_minor)
  );

  return jsonb_build_object(
    'branchId', p_branch_id,
    'menuItemId', p_menu_item_id,
    'priceOverrideMinor', p_price_minor
  );
end;
$$;

create or replace function public.remove_branch_price_override(
  p_branch_id uuid,
  p_menu_item_id uuid
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
  v_item_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  select mi.organization_id into v_item_org_id
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Branch or menu item belongs to another organization');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  update public.branch_menu_items
     set price_override_minor = null
   where branch_id = p_branch_id
     and menu_item_id = p_menu_item_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'menu.branch_price_override_removed', 'menu_item', p_menu_item_id, null, '{}'::jsonb
  );

  return jsonb_build_object('branchId', p_branch_id, 'menuItemId', p_menu_item_id);
end;
$$;

create or replace function public.create_table(
  p_branch_id uuid,
  p_label text,
  p_capacity integer
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
  v_table_id uuid;
  v_qr_public_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('BRANCH_NOT_FOUND', 'Branch was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Branch belongs to another organization');
  end if;

  perform authz.assert_branch_role(p_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_label), '') is null or p_capacity <= 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Table label and capacity are required');
  end if;

  insert into public.restaurant_tables (
    organization_id, branch_id, label, capacity
  )
  values (v_org_id, p_branch_id, btrim(p_label), p_capacity)
  returning id into v_table_id;

  insert into public.table_qr_identifiers (
    organization_id, branch_id, table_id
  )
  values (v_org_id, p_branch_id, v_table_id)
  returning public_id into v_qr_public_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'table.created', 'restaurant_table', v_table_id, null,
    jsonb_build_object('label', btrim(p_label), 'capacity', p_capacity)
  );

  return jsonb_build_object(
    'tableId', v_table_id,
    'branchId', p_branch_id,
    'qrPublicId', v_qr_public_id
  );
end;
$$;

create or replace function public.update_table(
  p_table_id uuid,
  p_label text,
  p_capacity integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_table_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  if v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Table belongs to another organization');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if nullif(btrim(p_label), '') is null or p_capacity <= 0 then
    perform private.raise_app_error('VALIDATION_ERROR', 'Table label and capacity are required');
  end if;

  update public.restaurant_tables
     set label = btrim(p_label),
         capacity = p_capacity
   where id = p_table_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'table.updated', 'restaurant_table', p_table_id, null,
    jsonb_build_object('label', btrim(p_label), 'capacity', p_capacity)
  );

  return jsonb_build_object('tableId', p_table_id, 'label', btrim(p_label), 'capacity', p_capacity);
end;
$$;

create or replace function public.deactivate_table(
  p_table_id uuid,
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
  v_branch_id uuid;
  v_table_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id;

  if v_table_org_id is null then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  if v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Table belongs to another organization');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  if exists (
    select 1
    from public.dining_sessions ds
    where ds.table_id = p_table_id
      and ds.status = 'active'
  ) then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'A table with an active dining session cannot be deactivated'
    );
  end if;

  update public.restaurant_tables
     set status = 'inactive',
         deactivated_at = now()
   where id = p_table_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'table.deactivated', 'restaurant_table', p_table_id,
    nullif(btrim(p_reason), ''), '{}'::jsonb
  );

  return jsonb_build_object('tableId', p_table_id, 'status', 'inactive');
end;
$$;

create or replace function public.regenerate_table_qr(p_table_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_table_org_id uuid;
  v_qr_public_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select rt.organization_id, rt.branch_id
    into v_table_org_id, v_branch_id
    from public.restaurant_tables rt
   where rt.id = p_table_id
   for update;

  if v_table_org_id is null then
    perform private.raise_app_error('TABLE_NOT_FOUND', 'Table was not found');
  end if;

  if v_table_org_id is distinct from v_org_id then
    perform private.raise_app_error('BRANCH_ACCESS_DENIED', 'Table belongs to another organization');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

  update public.table_qr_identifiers
     set revoked_at = now()
   where table_id = p_table_id
     and revoked_at is null;

  insert into public.table_qr_identifiers (
    organization_id, branch_id, table_id
  )
  values (v_org_id, v_branch_id, p_table_id)
  returning public_id into v_qr_public_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'table.qr_regenerated', 'restaurant_table', p_table_id, null,
    jsonb_build_object('qr_public_id', v_qr_public_id)
  );

  return jsonb_build_object('tableId', p_table_id, 'qrPublicId', v_qr_public_id);
end;
$$;

create or replace function public.resolve_or_create_dining_session(
  p_qr_public_id uuid,
  p_token_hash_hex text,
  p_device_label text default null,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_branch_id uuid;
  v_org_id uuid;
  v_table_label text;
  v_branch_name text;
  v_timezone text;
  v_currency_code text;
  v_session_id uuid;
  v_session_status public.dining_session_status;
  v_opened_at timestamptz;
  v_token_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    perform private.raise_app_error('PERMISSION_DENIED', 'Service role is required');
  end if;

  if p_token_hash_hex is null or p_token_hash_hex !~ '^[0-9a-f]{64}$' then
    perform private.raise_app_error('VALIDATION_ERROR', 'Token hash must be 64 lowercase hex characters');
  end if;

  if p_expires_at is null or p_expires_at <= now() then
    perform private.raise_app_error('VALIDATION_ERROR', 'Guest token expiry must be in the future');
  end if;

  select t.id, t.branch_id, t.organization_id, t.label,
         b.name, b.timezone, o.default_currency_code
    into v_table_id, v_branch_id, v_org_id, v_table_label,
         v_branch_name, v_timezone, v_currency_code
    from public.table_qr_identifiers tqr
    join public.restaurant_tables t
      on t.id = tqr.table_id
     and t.branch_id = tqr.branch_id
     and t.organization_id = tqr.organization_id
    join public.branches b
      on b.id = t.branch_id
     and b.organization_id = t.organization_id
    join public.organizations o
      on o.id = t.organization_id
   where tqr.public_id = p_qr_public_id
     and tqr.revoked_at is null
     and t.status = 'active'
     and b.status = 'active'
     and o.status = 'active';

  if v_table_id is null then
    perform private.raise_app_error('TABLE_QR_INVALID', 'Table QR is invalid or inactive');
  end if;

  -- New devices and new tokens are not issued while the subscription is
  -- restricted. Existing token holders use the reconnect/validation path.
  if authz.org_is_restricted(v_org_id) then
    perform private.raise_app_error(
      'SUBSCRIPTION_RESTRICTED',
      'New guest sessions and tokens are blocked while the organization subscription is restricted'
    );
  end if;

  perform 1
    from public.restaurant_tables rt
   where rt.id = v_table_id
   for update;

  select ds.id, ds.status, ds.opened_at
    into v_session_id, v_session_status, v_opened_at
    from public.dining_sessions ds
   where ds.table_id = v_table_id
     and ds.status = 'active'
   limit 1;

  if v_session_id is null then
    insert into public.dining_sessions (
      organization_id, branch_id, table_id
    )
    values (v_org_id, v_branch_id, v_table_id)
    returning id, status, opened_at
    into v_session_id, v_session_status, v_opened_at;
  end if;

  begin
    insert into private.guest_tokens (
      organization_id,
      branch_id,
      dining_session_id,
      token_hash,
      expires_at,
      device_label
    )
    values (
      v_org_id,
      v_branch_id,
      v_session_id,
      decode(p_token_hash_hex, 'hex'),
      p_expires_at,
      nullif(btrim(p_device_label), '')
    )
    returning id into v_token_id;
  exception
    when unique_violation then
      perform private.raise_app_error('RESOURCE_CONFLICT', 'Guest token hash already exists');
  end;

  return jsonb_build_object(
    'sessionId', v_session_id,
    'organizationId', v_org_id,
    'branchId', v_branch_id,
    'tableId', v_table_id,
    'tableLabel', v_table_label,
    'branchName', v_branch_name,
    'timezone', v_timezone,
    'currency', v_currency_code,
    'status', v_session_status,
    'openedAt', v_opened_at,
    'tokenExpiresAt', p_expires_at
  );
end;
$$;

create or replace function public.validate_guest_token(p_token_hash_hex text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token_id uuid;
  v_session_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_table_id uuid;
  v_table_label text;
  v_branch_name text;
  v_timezone text;
  v_currency_code text;
  v_session_status public.dining_session_status;
  v_opened_at timestamptz;
  v_expires_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' then
    perform private.raise_app_error('PERMISSION_DENIED', 'Service role is required');
  end if;

  if p_token_hash_hex is null or p_token_hash_hex !~ '^[0-9a-f]{64}$' then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid');
  end if;

  select gt.id, gt.dining_session_id, gt.organization_id, gt.branch_id,
         gt.expires_at, ds.table_id, rt.label, b.name, b.timezone,
         o.default_currency_code, ds.status, ds.opened_at
    into v_token_id, v_session_id, v_org_id, v_branch_id,
         v_expires_at, v_table_id, v_table_label, v_branch_name, v_timezone,
         v_currency_code, v_session_status, v_opened_at
    from private.guest_tokens gt
    join public.dining_sessions ds
      on ds.id = gt.dining_session_id
     and ds.branch_id = gt.branch_id
     and ds.organization_id = gt.organization_id
    join public.restaurant_tables rt
      on rt.id = ds.table_id
     and rt.branch_id = ds.branch_id
     and rt.organization_id = ds.organization_id
    join public.branches b
      on b.id = ds.branch_id
     and b.organization_id = ds.organization_id
    join public.organizations o
      on o.id = ds.organization_id
   where gt.token_hash = decode(p_token_hash_hex, 'hex')
     and gt.revoked_at is null
     and gt.expires_at > now()
     and ds.status = 'active'
   limit 1;

  if v_token_id is null then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token is invalid or expired');
  end if;

  update private.guest_tokens
     set last_used_at = now()
   where id = v_token_id;

  return jsonb_build_object(
    'sessionId', v_session_id,
    'organizationId', v_org_id,
    'branchId', v_branch_id,
    'tableId', v_table_id,
    'tableLabel', v_table_label,
    'branchName', v_branch_name,
    'timezone', v_timezone,
    'currency', v_currency_code,
    'status', v_session_status,
    'openedAt', v_opened_at,
    'tokenExpiresAt', v_expires_at
  );
end;
$$;

create or replace function public.get_guest_session_data(p_token_hash_hex text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_context jsonb;
  v_session_id uuid;
  v_orders jsonb;
begin
  v_context := public.validate_guest_token(p_token_hash_hex);
  v_session_id := (v_context ->> 'sessionId')::uuid;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'orderId', o.id,
        'status', o.status,
        'subtotalMinor', o.subtotal_minor,
        'createdAt', o.created_at,
        'items', (
          select coalesce(jsonb_agg(
            jsonb_build_object(
              'orderItemId', oi.id,
              'name', oi.item_name_snapshot,
              'quantity', oi.quantity,
              'status', oi.status,
              'lineTotalMinor', oi.line_total_minor
            )
          ), '[]'::jsonb)
          from public.order_items oi
          where oi.order_id = o.id
        )
      )
      order by o.created_at
    ),
    '[]'::jsonb
  )
    into v_orders
    from public.orders o
   where o.dining_session_id = v_session_id;

  return jsonb_build_object(
    'session', v_context,
    'orders', v_orders
  );
end;
$$;

create or replace function public.revoke_guest_token(
  p_token_id uuid,
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
  v_branch_id uuid;
  v_token_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := authz.current_organization_id();

  select gt.organization_id, gt.branch_id
    into v_token_org_id, v_branch_id
    from private.guest_tokens gt
   where gt.id = p_token_id;

  if v_token_org_id is null then
    perform private.raise_app_error('GUEST_TOKEN_INVALID', 'Guest token was not found');
  end if;

  if v_token_org_id is distinct from v_org_id then
    perform private.raise_app_error('ORGANIZATION_ACCESS_DENIED', 'Guest token belongs to another organization');
  end if;

  perform authz.assert_branch_role(v_branch_id, array['owner', 'admin', 'manager']::text[]);

  update private.guest_tokens
     set revoked_at = now()
   where id = p_token_id
     and revoked_at is null;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'guest_token.revoked', 'guest_token', p_token_id,
    nullif(btrim(p_reason), ''), '{}'::jsonb
  );

  return jsonb_build_object('tokenId', p_token_id, 'status', 'revoked');
end;
$$;

revoke all on function public.create_menu_category(text, text, integer) from public;
revoke all on function public.update_menu_category(uuid, text, text, integer) from public;
revoke all on function public.archive_menu_category(uuid) from public;
revoke all on function public.create_menu_item(uuid, text, bigint, text, integer) from public;
revoke all on function public.update_menu_item(uuid, text, bigint, text, integer) from public;
revoke all on function public.update_base_item_price(uuid, bigint) from public;
revoke all on function public.archive_menu_item(uuid) from public;
revoke all on function public.create_modifier_group(text, text, integer, integer) from public;
revoke all on function public.update_modifier_group(uuid, text, text, integer, integer) from public;
revoke all on function public.create_modifier_option(uuid, text, bigint, integer) from public;
revoke all on function public.update_modifier_option(uuid, text, bigint, integer) from public;
revoke all on function public.assign_modifier_group(uuid, uuid, integer) from public;
revoke all on function public.set_branch_item_availability(uuid, uuid, boolean) from public;
revoke all on function public.set_branch_price_override(uuid, uuid, bigint) from public;
revoke all on function public.remove_branch_price_override(uuid, uuid) from public;
revoke all on function public.create_table(uuid, text, integer) from public;
revoke all on function public.update_table(uuid, text, integer) from public;
revoke all on function public.deactivate_table(uuid, text) from public;
revoke all on function public.regenerate_table_qr(uuid) from public;
revoke all on function public.resolve_or_create_dining_session(uuid, text, text, timestamptz) from public;
revoke all on function public.validate_guest_token(text) from public;
revoke all on function public.get_guest_session_data(text) from public;
revoke all on function public.revoke_guest_token(uuid, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_menu_category(text, text, integer) to authenticated';
    execute 'grant execute on function public.update_menu_category(uuid, text, text, integer) to authenticated';
    execute 'grant execute on function public.archive_menu_category(uuid) to authenticated';
    execute 'grant execute on function public.create_menu_item(uuid, text, bigint, text, integer) to authenticated';
    execute 'grant execute on function public.update_menu_item(uuid, text, bigint, text, integer) to authenticated';
    execute 'grant execute on function public.update_base_item_price(uuid, bigint) to authenticated';
    execute 'grant execute on function public.archive_menu_item(uuid) to authenticated';
    execute 'grant execute on function public.create_modifier_group(text, text, integer, integer) to authenticated';
    execute 'grant execute on function public.update_modifier_group(uuid, text, text, integer, integer) to authenticated';
    execute 'grant execute on function public.create_modifier_option(uuid, text, bigint, integer) to authenticated';
    execute 'grant execute on function public.update_modifier_option(uuid, text, bigint, integer) to authenticated';
    execute 'grant execute on function public.assign_modifier_group(uuid, uuid, integer) to authenticated';
    execute 'grant execute on function public.set_branch_item_availability(uuid, uuid, boolean) to authenticated';
    execute 'grant execute on function public.set_branch_price_override(uuid, uuid, bigint) to authenticated';
    execute 'grant execute on function public.remove_branch_price_override(uuid, uuid) to authenticated';
    execute 'grant execute on function public.create_table(uuid, text, integer) to authenticated';
    execute 'grant execute on function public.update_table(uuid, text, integer) to authenticated';
    execute 'grant execute on function public.deactivate_table(uuid, text) to authenticated';
    execute 'grant execute on function public.regenerate_table_qr(uuid) to authenticated';
    execute 'grant execute on function public.revoke_guest_token(uuid, text) to authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.resolve_or_create_dining_session(uuid, text, text, timestamptz) to service_role';
    execute 'grant execute on function public.validate_guest_token(text) to service_role';
    execute 'grant execute on function public.get_guest_session_data(text) to service_role';
  end if;
end
$$;

