-- M3 core POS operations: additive order schema extensions.
--
-- The existing foundation order lifecycle ends at `served`. M3 adds an explicit
-- operational `completed` state so that order completion is not confused with
-- payment settlement or dining-session closure. The enum value is added in its
-- own migration because PostgreSQL cannot safely use a newly added enum value in
-- the same transaction that adds it.
--
-- order_reference is a stable, non-financial reference for POS displays and
-- audit correlation. It is deliberately not a per-branch business sequence; the
-- deferred human display-numbering contract remains out of scope.

alter type public.order_status
  add value if not exists 'completed' after 'served';

create sequence if not exists private.order_reference_seq;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage, select on sequence private.order_reference_seq to service_role';
  end if;
end
$$;

alter table public.orders
  add column if not exists order_reference text;

update public.orders
   set order_reference =
         'ORD-' || lpad(nextval('private.order_reference_seq')::text, 8, '0')
 where order_reference is null;

alter table public.orders
  alter column order_reference
    set default ('ORD-' || lpad(nextval('private.order_reference_seq')::text, 8, '0')),
  alter column order_reference set not null;

-- Keep this file safe to retry after a partial operational failure. PostgreSQL
-- has no `add constraint if not exists`, so check the catalog first.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'orders_order_reference_unique'
      and conrelid = 'public.orders'::regclass
  ) then
    alter table public.orders
      add constraint orders_order_reference_unique unique (order_reference);
  end if;
end
$$;

alter table public.orders
  add column if not exists completed_at timestamptz;

comment on column public.orders.order_reference is
  'Stable non-financial order reference generated at insert. Distinct from deferred per-branch display numbering.';

comment on column public.orders.completed_at is
  'Operational completion timestamp. Independent of payment settlement and dining-session closure.';

comment on type public.order_status is
  'Operational order states: pending, accepted (staff-confirmed), preparing, ready, served, completed, cancelled. Payment state is separate.';
