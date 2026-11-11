-- M4.3: Application-facing kitchen station and routing management.
--
-- Scope:
--   * Create, rename, deactivate, and reactivate a branch-scoped station.
--   * Add/remove category-level and item-level menu routes.
--   * List stations with their complete routing configuration.
--   * Audit every configuration write through private.audit_write.
--
-- Authorization:
--   * Owner/Admin/Manager in the station branch may write configuration.
--   * Kitchen Staff may read configuration but cannot mutate it.
--   * Cashier and anonymous clients are denied.
--
-- Deactivation is configuration-only: it prevents future ticket routing and
-- never cancels existing tickets. Reactivation restores the existing routes.
--
-- Design: docs/m4-kitchen-infrastructure.md and docs/m4-kitchen-ticket-lifecycle.md.
--
-- approved-destructive-change: m4-3-kitchen-station-route-removal
-- Route removal is the intended DELETE operation for configuration rows. It
-- never deletes stations, tickets, ticket items, or audit history.

-- ---------------------------------------------------------------------------
-- 1. Station configuration read helper
-- ---------------------------------------------------------------------------

create or replace function private.kitchen_station_json(p_station_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'stationId', s.id,
    'organizationId', s.organization_id,
    'branchId', s.branch_id,
    'name', s.name,
    'description', s.description,
    'status', s.status,
    'deactivatedAt', s.deactivated_at,
    'createdAt', s.created_at,
    'updatedAt', s.updated_at,
    'categoryRoutes', coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'routeId', cr.id,
                   'menuCategoryId', cr.menu_category_id,
                   'menuCategoryName', mc.name,
                   'createdAt', cr.created_at,
                   'updatedAt', cr.updated_at
                 )
                 order by lower(btrim(mc.name)), cr.id
               )
        from public.kitchen_station_menu_categories cr
        join public.menu_categories mc
          on mc.id = cr.menu_category_id
         and mc.organization_id = cr.organization_id
        where cr.station_id = s.id
          and cr.organization_id = s.organization_id
          and cr.branch_id = s.branch_id
      ),
      '[]'::jsonb
    ),
    'itemRoutes', coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'routeId', ir.id,
                   'menuItemId', ir.menu_item_id,
                   'menuItemName', mi.name,
                   'menuCategoryId', mc.id,
                   'menuCategoryName', mc.name,
                   'createdAt', ir.created_at,
                   'updatedAt', ir.updated_at
                 )
                 order by lower(btrim(mi.name)), ir.id
               )
        from public.kitchen_station_menu_items ir
        join public.menu_items mi
          on mi.id = ir.menu_item_id
         and mi.organization_id = ir.organization_id
        join public.menu_categories mc
          on mc.id = mi.category_id
         and mc.organization_id = mi.organization_id
        where ir.station_id = s.id
          and ir.organization_id = s.organization_id
          and ir.branch_id = s.branch_id
      ),
      '[]'::jsonb
    )
  )
  from public.kitchen_stations s
  where s.id = p_station_id;
$$;

revoke all on function private.kitchen_station_json(uuid) from public;

comment on function private.kitchen_station_json(uuid) is
  'Contract-shaped station JSON, including category and item routing configuration. Used only by authorized public RPCs.';

-- ---------------------------------------------------------------------------
-- 2. Configuration authorization helper
-- ---------------------------------------------------------------------------

create or replace function private.assert_kitchen_station_admin(p_branch_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
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

  return v_org_id;
end;
$$;

revoke all on function private.assert_kitchen_station_admin(uuid) from public;

comment on function private.assert_kitchen_station_admin(uuid) is
  'Requires an active Owner/Admin/Manager branch role for a branch in the caller organization and returns the organization id.';

-- ---------------------------------------------------------------------------
-- 3. Station lifecycle RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_kitchen_station(
  p_branch_id uuid,
  p_name text,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_station_id uuid;
  v_name text := btrim(p_name);
begin
  v_actor_staff_id := authz.require_staff_id();
  v_org_id := private.assert_kitchen_station_admin(p_branch_id);

  if nullif(v_name, '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Station name is required');
  end if;

  if length(v_name) > 200 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Station name cannot exceed 200 characters'
    );
  end if;

  if p_description is not null and length(btrim(p_description)) > 1000 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Station description cannot exceed 1000 characters'
    );
  end if;

  begin
    insert into public.kitchen_stations (
      organization_id,
      branch_id,
      name,
      description
    )
    values (
      v_org_id,
      p_branch_id,
      v_name,
      nullif(btrim(p_description), '')
    )
    returning id into v_station_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'A kitchen station with this name already exists in the branch'
      );
  end;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, p_branch_id,
    'kitchen.station_created', 'kitchen_station', v_station_id, null,
    jsonb_build_object('name', v_name)
  );

  return private.kitchen_station_json(v_station_id);
end;
$$;

create or replace function public.update_kitchen_station(
  p_station_id uuid,
  p_name text,
  p_description text default null
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
  v_station public.kitchen_stations%rowtype;
  v_name text := btrim(p_name);
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  if nullif(v_name, '') is null then
    perform private.raise_app_error('VALIDATION_ERROR', 'Station name is required');
  end if;

  if length(v_name) > 200 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Station name cannot exceed 200 characters'
    );
  end if;

  if p_description is not null and length(btrim(p_description)) > 1000 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Station description cannot exceed 1000 characters'
    );
  end if;

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  begin
    update public.kitchen_stations
       set name = v_name,
           description = nullif(btrim(p_description), '')
     where id = p_station_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'A kitchen station with this name already exists in the branch'
      );
  end;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.station_updated', 'kitchen_station', p_station_id, null,
    jsonb_build_object(
      'old_name', v_station.name,
      'new_name', v_name
    )
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

create or replace function public.deactivate_kitchen_station(
  p_station_id uuid,
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
  v_branch_id uuid;
  v_station public.kitchen_stations%rowtype;
  v_reason text := nullif(btrim(p_reason), '');
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  if v_reason is not null and length(v_reason) > 500 then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'Deactivation reason cannot exceed 500 characters'
    );
  end if;

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  -- Repeated deactivation is an idempotent no-op and does not add audit noise.
  if v_station.status = 'inactive' then
    return private.kitchen_station_json(p_station_id);
  end if;

  update public.kitchen_stations
     set status = 'inactive',
         deactivated_at = now()
   where id = p_station_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.station_deactivated', 'kitchen_station', p_station_id, v_reason,
    jsonb_build_object('name', v_station.name)
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

create or replace function public.reactivate_kitchen_station(p_station_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_staff_id uuid;
  v_org_id uuid;
  v_branch_id uuid;
  v_station public.kitchen_stations%rowtype;
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  if v_station.status = 'active' then
    return private.kitchen_station_json(p_station_id);
  end if;

  update public.kitchen_stations
     set status = 'active',
         deactivated_at = null
   where id = p_station_id;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.station_reactivated', 'kitchen_station', p_station_id, null,
    jsonb_build_object('name', v_station.name)
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Category route RPCs
-- ---------------------------------------------------------------------------

create or replace function public.add_kitchen_station_category_route(
  p_station_id uuid,
  p_menu_category_id uuid
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
  v_station public.kitchen_stations%rowtype;
  v_category_org_id uuid;
  v_route_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  if v_station.status <> 'active' then
    perform private.raise_app_error(
      'KITCHEN_STATION_INACTIVE',
      'Routes cannot be added to an inactive kitchen station'
    );
  end if;

  select mc.organization_id
    into v_category_org_id
    from public.menu_categories mc
   where mc.id = p_menu_category_id;

  if v_category_org_id is null
     or v_category_org_id is distinct from v_org_id
  then
    perform private.raise_app_error(
      'MENU_ITEM_NOT_FOUND',
      'Menu category was not found'
    );
  end if;

  begin
    insert into public.kitchen_station_menu_categories (
      organization_id,
      branch_id,
      station_id,
      menu_category_id
    )
    values (
      v_org_id,
      v_branch_id,
      p_station_id,
      p_menu_category_id
    )
    returning id into v_route_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'This category is already routed to the station'
      );
  end;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.category_route_added', 'kitchen_station_category_route',
    v_route_id, null,
    jsonb_build_object(
      'station_id', p_station_id,
      'menu_category_id', p_menu_category_id
    )
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

create or replace function public.remove_kitchen_station_category_route(
  p_station_id uuid,
  p_menu_category_id uuid
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
  v_station public.kitchen_stations%rowtype;
  v_route_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  delete from public.kitchen_station_menu_categories cr
   where cr.station_id = p_station_id
     and cr.organization_id = v_org_id
     and cr.branch_id = v_branch_id
     and cr.menu_category_id = p_menu_category_id
  returning cr.id into v_route_id;

  if v_route_id is null then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'This category route was not found'
    );
  end if;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.category_route_removed', 'kitchen_station_category_route',
    v_route_id, null,
    jsonb_build_object(
      'station_id', p_station_id,
      'menu_category_id', p_menu_category_id
    )
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Item route RPCs
-- ---------------------------------------------------------------------------

create or replace function public.add_kitchen_station_item_route(
  p_station_id uuid,
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
  v_branch_id uuid;
  v_station public.kitchen_stations%rowtype;
  v_item_org_id uuid;
  v_route_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  if v_station.status <> 'active' then
    perform private.raise_app_error(
      'KITCHEN_STATION_INACTIVE',
      'Routes cannot be added to an inactive kitchen station'
    );
  end if;

  select mi.organization_id
    into v_item_org_id
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if v_item_org_id is null
     or v_item_org_id is distinct from v_org_id
  then
    perform private.raise_app_error(
      'MENU_ITEM_NOT_FOUND',
      'Menu item was not found'
    );
  end if;

  begin
    insert into public.kitchen_station_menu_items (
      organization_id,
      branch_id,
      station_id,
      menu_item_id
    )
    values (
      v_org_id,
      v_branch_id,
      p_station_id,
      p_menu_item_id
    )
    returning id into v_route_id;
  exception
    when unique_violation then
      perform private.raise_app_error(
        'RESOURCE_CONFLICT',
        'This menu item is already routed to the station'
      );
  end;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.item_route_added', 'kitchen_station_item_route',
    v_route_id, null,
    jsonb_build_object(
      'station_id', p_station_id,
      'menu_item_id', p_menu_item_id
    )
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

create or replace function public.remove_kitchen_station_item_route(
  p_station_id uuid,
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
  v_branch_id uuid;
  v_station public.kitchen_stations%rowtype;
  v_route_id uuid;
begin
  v_actor_staff_id := authz.require_staff_id();

  select s.organization_id, s.branch_id
    into v_org_id, v_branch_id
    from public.kitchen_stations s
   where s.id = p_station_id;

  if v_org_id is null
     or v_org_id is distinct from authz.current_organization_id()
  then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  v_org_id := private.assert_kitchen_station_admin(v_branch_id);

  select *
    into v_station
    from public.kitchen_stations s
   where s.id = p_station_id
   for update;

  if not found then
    perform private.raise_app_error(
      'KITCHEN_STATION_NOT_FOUND',
      'Kitchen station was not found'
    );
  end if;

  delete from public.kitchen_station_menu_items ir
   where ir.station_id = p_station_id
     and ir.organization_id = v_org_id
     and ir.branch_id = v_branch_id
     and ir.menu_item_id = p_menu_item_id
  returning ir.id into v_route_id;

  if v_route_id is null then
    perform private.raise_app_error(
      'RESOURCE_CONFLICT',
      'This item route was not found'
    );
  end if;

  perform private.audit_write(
    'staff', v_actor_staff_id, null, v_org_id, v_branch_id,
    'kitchen.item_route_removed', 'kitchen_station_item_route',
    v_route_id, null,
    jsonb_build_object(
      'station_id', p_station_id,
      'menu_item_id', p_menu_item_id
    )
  );

  return private.kitchen_station_json(p_station_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Station configuration read RPC
-- ---------------------------------------------------------------------------

create or replace function public.list_kitchen_stations(p_branch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_stations jsonb;
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
    array['owner', 'admin', 'manager', 'kitchen_staff']::text[]
  );

  select coalesce(
           jsonb_agg(
             private.kitchen_station_json(s.id)
             order by lower(btrim(s.name)), s.id
           ),
           '[]'::jsonb
         )
    into v_stations
    from public.kitchen_stations s
   where s.organization_id = v_org_id
     and s.branch_id = p_branch_id;

  return jsonb_build_object(
    'branchId', p_branch_id,
    'stations', v_stations
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants and comments
-- ---------------------------------------------------------------------------

revoke all on function public.create_kitchen_station(uuid, text, text) from public;
revoke all on function public.update_kitchen_station(uuid, text, text) from public;
revoke all on function public.deactivate_kitchen_station(uuid, text) from public;
revoke all on function public.reactivate_kitchen_station(uuid) from public;
revoke all on function public.add_kitchen_station_category_route(uuid, uuid) from public;
revoke all on function public.remove_kitchen_station_category_route(uuid, uuid) from public;
revoke all on function public.add_kitchen_station_item_route(uuid, uuid) from public;
revoke all on function public.remove_kitchen_station_item_route(uuid, uuid) from public;
revoke all on function public.list_kitchen_stations(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_kitchen_station(uuid, text, text) to authenticated';
    execute 'grant execute on function public.update_kitchen_station(uuid, text, text) to authenticated';
    execute 'grant execute on function public.deactivate_kitchen_station(uuid, text) to authenticated';
    execute 'grant execute on function public.reactivate_kitchen_station(uuid) to authenticated';
    execute 'grant execute on function public.add_kitchen_station_category_route(uuid, uuid) to authenticated';
    execute 'grant execute on function public.remove_kitchen_station_category_route(uuid, uuid) to authenticated';
    execute 'grant execute on function public.add_kitchen_station_item_route(uuid, uuid) to authenticated';
    execute 'grant execute on function public.remove_kitchen_station_item_route(uuid, uuid) to authenticated';
    execute 'grant execute on function public.list_kitchen_stations(uuid) to authenticated';
  end if;
end
$$;

comment on function public.create_kitchen_station(uuid, text, text) is
  'Creates a branch-scoped kitchen station. Requires Owner/Admin/Manager in the branch. Station names are unique per branch using a case-insensitive trimmed comparison.';

comment on function public.update_kitchen_station(uuid, text, text) is
  'Renames or updates the description of a kitchen station. Requires Owner/Admin/Manager in the station branch.';

comment on function public.deactivate_kitchen_station(uuid, text) is
  'Marks a station inactive and records deactivated_at. Existing routes and tickets are preserved; new ticket routing skips the station. Requires Owner/Admin/Manager.';

comment on function public.reactivate_kitchen_station(uuid) is
  'Marks a station active and clears deactivated_at. Existing routes take effect again. Requires Owner/Admin/Manager.';

comment on function public.add_kitchen_station_category_route(uuid, uuid) is
  'Routes a menu category to an active station in the same organization. Requires Owner/Admin/Manager.';

comment on function public.remove_kitchen_station_category_route(uuid, uuid) is
  'Removes a category route from a station. Existing tickets are not retroactively rerouted. Requires Owner/Admin/Manager.';

comment on function public.add_kitchen_station_item_route(uuid, uuid) is
  'Routes a menu item to an active station in the same organization. Item routes take precedence over category routes. Requires Owner/Admin/Manager.';

comment on function public.remove_kitchen_station_item_route(uuid, uuid) is
  'Removes an item route from a station. Existing tickets are not retroactively rerouted. Requires Owner/Admin/Manager.';

comment on function public.list_kitchen_stations(uuid) is
  'Lists kitchen stations and their routing configuration for an accessible branch. Owner/Admin/Manager/Kitchen Staff may read; Cashier is denied.';
