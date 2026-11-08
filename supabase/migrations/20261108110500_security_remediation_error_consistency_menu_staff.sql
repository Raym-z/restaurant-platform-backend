-- Security remediation: normalize cross-tenant resource errors in remaining
-- menu and staff administration RPCs.

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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu category belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu category belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu category belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Modifier group belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Modifier group belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Modifier option belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item or modifier group belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_org_id);

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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Branch was not found');
  end if;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Branch or menu item belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Branch was not found');
  end if;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Branch or menu item belongs to another organization');
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
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Branch was not found');
  end if;

  if v_item_org_id is null then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Menu item was not found');
  end if;

  if v_branch_org_id is distinct from v_org_id
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error('MENU_ITEM_NOT_FOUND', 'Branch or menu item belongs to another organization');
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


create or replace function public.grant_staff_role(
  p_staff_id uuid,
  p_role_code text,
  p_scope_type public.role_scope,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
  v_assignment_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if p_role_code = 'owner' then
    perform private.raise_app_error(
      'PERMISSION_DENIED',
      'Ownership transfer is not available in the initial release'
    );
  end if;

  if p_role_code = 'admin' and not authz.has_org_role(array['owner']::text[]) then
    perform private.raise_app_error(
      'PERMISSION_DENIED',
      'Only the Owner may grant the Admin role'
    );
  end if;

  if p_role_code not in ('admin', 'manager', 'cashier', 'kitchen_staff') then
    perform private.raise_app_error('VALIDATION_ERROR', 'Unsupported role');
  end if;

  if p_role_code in ('manager', 'cashier', 'kitchen_staff')
     and p_scope_type <> 'branch'
  then
    perform private.raise_app_error('VALIDATION_ERROR', 'This role requires branch scope');
  end if;

  begin
    insert into public.staff_role_assignments (
      staff_id,
      organization_id,
      role_code,
      scope_type,
      assigned_by_staff_id,
      reason
    )
    values (
      p_staff_id,
      v_actor_org_id,
      p_role_code,
      p_scope_type,
      v_actor_staff_id,
      nullif(btrim(p_reason), '')
    )
    returning id into v_assignment_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'An equivalent active role assignment already exists'
      );
  end;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.role_granted',
    'staff',
    p_staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('role_code', p_role_code, 'scope_type', p_scope_type)
  );

  return jsonb_build_object(
    'assignmentId', v_assignment_id,
    'staffId', p_staff_id,
    'roleCode', p_role_code,
    'scope', p_scope_type
  );
end;
$$;

create or replace function public.revoke_staff_role(
  p_assignment_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_assignment public.staff_role_assignments%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select * into v_assignment
    from public.staff_role_assignments sra
   where sra.id = p_assignment_id;

  if not found then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment was not found');
  end if;

  if v_assignment.organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Role assignment belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if v_assignment.role_code = 'admin'
     and not authz.has_org_role(array['owner']::text[])
  then
    perform private.raise_app_error('PERMISSION_DENIED', 'Only the Owner may revoke the Admin role');
  end if;

  if v_assignment.revoked_at is not null then
    return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'already_revoked');
  end if;

  update public.staff_role_assignments
     set revoked_at = now(),
         revoked_by_staff_id = v_actor_staff_id,
         reason = nullif(btrim(p_reason), '')
   where id = p_assignment_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.role_revoked',
    'staff',
    v_assignment.staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('role_code', v_assignment.role_code, 'scope_type', v_assignment.scope_type)
  );

  return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'revoked');
end;
$$;

create or replace function public.assign_staff_branch(
  p_staff_id uuid,
  p_branch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
  v_branch_org_id uuid;
  v_assignment_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  select b.organization_id into v_branch_org_id
    from public.branches b
   where b.id = p_branch_id;

  if v_branch_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id
     or v_branch_org_id is distinct from v_actor_org_id
  then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff or branch belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  begin
    insert into public.staff_branch_assignments (
      staff_id,
      organization_id,
      branch_id,
      assigned_by_staff_id
    )
    values (
      p_staff_id,
      v_actor_org_id,
      p_branch_id,
      v_actor_staff_id
    )
    returning id into v_assignment_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'An equivalent active branch assignment already exists'
      );
  end;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    p_branch_id,
    'staff.branch_assigned',
    'staff',
    p_staff_id,
    null,
    jsonb_build_object('branch_id', p_branch_id)
  );

  return jsonb_build_object(
    'assignmentId', v_assignment_id,
    'staffId', p_staff_id,
    'branchId', p_branch_id
  );
end;
$$;

create or replace function public.revoke_staff_branch(
  p_assignment_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_assignment public.staff_branch_assignments%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select * into v_assignment
    from public.staff_branch_assignments sba
   where sba.id = p_assignment_id;

  if not found then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch assignment was not found');
  end if;

  if v_assignment.organization_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Branch assignment belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  if v_assignment.revoked_at is not null then
    return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'already_revoked');
  end if;

  update public.staff_branch_assignments
     set revoked_at = now()
   where id = p_assignment_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    v_assignment.branch_id,
    'staff.branch_revoked',
    'staff',
    v_assignment.staff_id,
    nullif(btrim(p_reason), ''),
    jsonb_build_object('branch_id', v_assignment.branch_id)
  );

  return jsonb_build_object('assignmentId', p_assignment_id, 'status', 'revoked');
end;
$$;

create or replace function public.deactivate_staff(
  p_staff_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  if p_staff_id = v_actor_staff_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'You cannot deactivate your own membership');
  end if;

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  update public.staff_profiles
     set status = 'deactivated',
         deactivated_at = now()
   where id = p_staff_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.deactivated',
    'staff',
    p_staff_id,
    nullif(btrim(p_reason), ''),
    '{}'::jsonb
  );

  return jsonb_build_object('staffId', p_staff_id, 'status', 'deactivated');
end;
$$;

create or replace function public.reactivate_staff(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member belongs to another organization');
  end if;

  perform authz.assert_org_role(array['owner', 'admin']::text[]);
  perform authz.assert_org_can_administer(v_actor_org_id);

  update public.staff_profiles
     set status = 'active',
         activated_at = now(),
         deactivated_at = null
   where id = p_staff_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.reactivated',
    'staff',
    p_staff_id,
    null,
    '{}'::jsonb
  );

  return jsonb_build_object('staffId', p_staff_id, 'status', 'active');
end;
$$;

create or replace function public.update_staff_profile(
  p_staff_id uuid,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_actor_org_id uuid;
  v_target_org_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();
  v_actor_org_id := authz.current_organization_id();

  select sp.organization_id into v_target_org_id
    from public.staff_profiles sp
   where sp.id = p_staff_id;

  if v_target_org_id is null then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member was not found');
  end if;

  if v_target_org_id is distinct from v_actor_org_id then
    perform private.raise_app_error('RESOURCE_CONFLICT', 'Staff member belongs to another organization');
  end if;

  if p_staff_id <> v_actor_staff_id then
    perform authz.assert_org_role(array['owner', 'admin']::text[]);
    perform authz.assert_org_can_administer(v_actor_org_id);
  end if;

  if nullif(btrim(p_display_name), '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Display name is required');
  end if;

  update public.staff_profiles
     set display_name = btrim(p_display_name)
   where id = p_staff_id;

  perform private.audit_write(
    'staff',
    v_actor_staff_id,
    null,
    v_actor_org_id,
    null,
    'staff.profile_updated',
    'staff',
    p_staff_id,
    null,
    jsonb_build_object('display_name', btrim(p_display_name))
  );

  return jsonb_build_object('staffId', p_staff_id, 'displayName', btrim(p_display_name));
end;
$$;

