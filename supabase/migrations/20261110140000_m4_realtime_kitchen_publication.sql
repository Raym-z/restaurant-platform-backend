-- M4.3: Realtime publication for the kitchen display system.
--
-- Publication membership is added only for the approved kitchen tables:
--   * kitchen_tickets
--   * kitchen_ticket_items
--   * kitchen_stations
--   * kitchen_station_menu_items
--   * kitchen_station_menu_categories
--
-- Existing branch-scoped SELECT RLS policies remain the authorization boundary.
-- Channel names and client-side filters are conveniences, never authorization.
--
-- Replica identity:
--   * Tickets, ticket items, and stations are never deleted by normal flows.
--     Their default (primary key) identity is sufficient for INSERT/UPDATE.
--   * Route tables use DELETE for route removal. FULL identity is required so
--     Realtime can apply the branch-scoped RLS policy to the old row.
--
-- Verification status: the publication and identity configuration are
-- implemented, but branch-isolation delivery tests require a running local
-- Supabase stack. BLK-008 remains open until those tests pass. Polling remains
-- the supported fallback.

do $$
declare
  v_table text;
  v_tables text[] := array[
    'kitchen_tickets',
    'kitchen_ticket_items',
    'kitchen_stations',
    'kitchen_station_menu_items',
    'kitchen_station_menu_categories'
  ];
begin
  if not exists (
    select 1
    from pg_publication p
    where p.pubname = 'supabase_realtime'
  ) then
    create publication supabase_realtime;
  end if;

  foreach v_table in array v_tables
  loop
    if not exists (
      select 1
      from pg_publication_tables pt
      where pt.pubname = 'supabase_realtime'
        and pt.schemaname = 'public'
        and pt.tablename = v_table
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        v_table
      );
    end if;
  end loop;
end
$$;

-- Route removal is a DELETE event in normal application flows. FULL identity
-- lets Realtime evaluate the branch-scoped SELECT policy against the old row.
alter table public.kitchen_station_menu_categories
  replica identity full;

alter table public.kitchen_station_menu_items
  replica identity full;

comment on table public.kitchen_station_menu_categories is
  'Category-level kitchen routing. Realtime uses DELETE events for route removal; replica identity FULL is required for branch-scoped RLS delivery.';

comment on table public.kitchen_station_menu_items is
  'Item-level kitchen routing. Realtime uses DELETE events for route removal; replica identity FULL is required for branch-scoped RLS delivery.';
