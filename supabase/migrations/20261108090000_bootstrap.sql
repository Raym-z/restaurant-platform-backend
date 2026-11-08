-- Database foundation bootstrap.
--
-- Owned by the database-foundation workstream. RLS policies, client grants,
-- authorization helper functions, RPCs, and Edge Functions are owned by the
-- backend-services workstream and are intentionally not defined here.

create schema if not exists private;

comment on schema private is
  'Non-exposed internal schema. Store guest token hashes, idempotency records, and internal trigger functions here. Client roles must not have usage.';

revoke all on schema private from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema private from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on schema private from authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema private to service_role';
  end if;
end
$$;

-- Protect future objects created by the migration role. Per-table grants or
-- revokes are still applied in every table migration because default
-- privileges are role-specific and do not cover objects created by other roles.
do $$
begin
  execute 'alter default privileges in schema public revoke all on tables from public';
  execute 'alter default privileges in schema public revoke all on sequences from public';
  execute 'alter default privileges in schema public revoke all on functions from public';

  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'alter default privileges in schema public revoke all on tables from anon';
    execute 'alter default privileges in schema public revoke all on sequences from anon';
    execute 'alter default privileges in schema public revoke all on functions from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'alter default privileges in schema public revoke all on tables from authenticated';
    execute 'alter default privileges in schema public revoke all on sequences from authenticated';
    execute 'alter default privileges in schema public revoke all on functions from authenticated';
  end if;

  execute 'alter default privileges in schema private revoke all on tables from public';
  execute 'alter default privileges in schema private revoke all on sequences from public';
  execute 'alter default privileges in schema private revoke all on functions from public';

  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'alter default privileges in schema private revoke all on tables from anon';
    execute 'alter default privileges in schema private revoke all on sequences from anon';
    execute 'alter default privileges in schema private revoke all on functions from anon';
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'alter default privileges in schema private revoke all on tables from authenticated';
    execute 'alter default privileges in schema private revoke all on sequences from authenticated';
    execute 'alter default privileges in schema private revoke all on functions from authenticated';
  end if;

  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'alter default privileges in schema private grant all on tables to service_role';
    execute 'alter default privileges in schema private grant all on sequences to service_role';
    execute 'alter default privileges in schema private grant all on functions to service_role';
  end if;
end
$$;

-- Stable controlled states. Lookup/configuration values that are expected to
-- evolve remain lookup tables in the domain migrations.
create type public.organization_status as enum (
  'active',
  'suspended',
  'pending_deletion'
);

create type public.branch_status as enum (
  'active',
  'inactive'
);

create type public.subscription_state as enum (
  'active',
  'expired',
  'grace_period',
  'restricted'
);

create type public.staff_status as enum (
  'invited',
  'active',
  'suspended',
  'deactivated'
);

create type public.role_scope as enum (
  'organization',
  'branch'
);

create type public.table_status as enum (
  'active',
  'inactive'
);

create type public.dining_session_status as enum (
  'active',
  'closed'
);

create type public.order_status as enum (
  'pending',
  'accepted',
  'preparing',
  'ready',
  'served',
  'cancelled'
);

create type public.order_item_status as enum (
  'pending',
  'accepted',
  'preparing',
  'ready',
  'served',
  'cancelled'
);

create type public.order_source as enum (
  'guest',
  'staff'
);

create type public.bill_status as enum (
  'finalized',
  'settled',
  'voided'
);

create type public.payment_method as enum (
  'cash'
);

create type public.payment_status as enum (
  'completed',
  'voided'
);

create type public.waitlist_status as enum (
  'waiting',
  'notified',
  'seated',
  'cancelled',
  'no_show'
);

create type public.discount_type as enum (
  'fixed_amount',
  'percentage'
);

create type public.charge_type as enum (
  'tax',
  'service_charge'
);

create type public.calculation_type as enum (
  'percentage',
  'fixed_amount'
);

create type public.audit_actor_type as enum (
  'staff',
  'customer',
  'platform_admin',
  'system',
  'guest'
);

create type public.idempotency_status as enum (
  'pending',
  'completed',
  'failed'
);

create type public.idempotency_scope as enum (
  'auth_user',
  'organization',
  'staff',
  'customer',
  'guest_session',
  'platform_admin'
);

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function private.validate_iana_timezone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names
       where name = new.timezone
     )
  then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_BRANCH_TIMEZONE';
  end if;

  return new;
end;
$$;

create or replace function private.validate_role_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.role_code = 'owner' and new.scope_type <> 'organization' then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.role_code in ('manager', 'cashier', 'kitchen_staff')
     and new.scope_type <> 'branch'
  then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  if new.role_code not in ('owner', 'admin', 'manager', 'cashier', 'kitchen_staff') then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_ROLE_SCOPE';
  end if;

  return new;
end;
$$;

create or replace function private.guard_bill_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.branch_id is distinct from old.branch_id
     or new.dining_session_id is distinct from old.dining_session_id
     or new.currency_code is distinct from old.currency_code
     or new.subtotal_minor is distinct from old.subtotal_minor
     or new.discount_total_minor is distinct from old.discount_total_minor
     or new.tax_total_minor is distinct from old.tax_total_minor
     or new.service_charge_total_minor is distinct from old.service_charge_total_minor
     or new.grand_total_minor is distinct from old.grand_total_minor
     or new.tax_configuration_snapshot is distinct from old.tax_configuration_snapshot
     or new.service_charge_configuration_snapshot is distinct from old.service_charge_configuration_snapshot
     or new.finalized_at is distinct from old.finalized_at
     or new.finalized_by_staff_id is distinct from old.finalized_by_staff_id
  then
    raise exception using
      errcode = 'P0001',
      message = 'BILL_IMMUTABLE';
  end if;

  return new;
end;
$$;

create or replace function private.guard_order_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.branch_id is distinct from old.branch_id
     or new.dining_session_id is distinct from old.dining_session_id
     or new.source is distinct from old.source
     or new.currency_code is distinct from old.currency_code
     or new.subtotal_minor is distinct from old.subtotal_minor
     or new.submitted_by_staff_id is distinct from old.submitted_by_staff_id
     or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'P0001',
      message = 'ORDER_IMMUTABLE';
  end if;

  return new;
end;
$$;

create or replace function private.guard_order_item_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.order_id is distinct from old.order_id
     or new.organization_id is distinct from old.organization_id
     or new.branch_id is distinct from old.branch_id
     or new.menu_item_id is distinct from old.menu_item_id
     or new.item_name_snapshot is distinct from old.item_name_snapshot
     or new.base_unit_price_minor is distinct from old.base_unit_price_minor
     or new.modifier_unit_delta_minor is distinct from old.modifier_unit_delta_minor
     or new.quantity is distinct from old.quantity
     or new.currency_code is distinct from old.currency_code
     or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'P0001',
      message = 'ORDER_ITEM_IMMUTABLE';
  end if;

  return new;
end;
$$;

create or replace function private.guard_order_item_modifier_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'ORDER_ITEM_MODIFIER_IMMUTABLE';
end;
$$;

create or replace function private.guard_payment_amounts()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.bill_id is distinct from old.bill_id
     or new.method is distinct from old.method
     or new.currency_code is distinct from old.currency_code
     or new.amount_due_minor is distinct from old.amount_due_minor
     or new.cash_received_minor is distinct from old.cash_received_minor
     or new.change_minor is distinct from old.change_minor
     or new.recorded_by_staff_id is distinct from old.recorded_by_staff_id
     or new.paid_at is distinct from old.paid_at
  then
    raise exception using
      errcode = 'P0001',
      message = 'PAYMENT_IMMUTABLE';
  end if;

  return new;
end;
$$;

create or replace function private.validate_payment_full_settlement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bill record;
begin
  select b.grand_total_minor, b.currency_code, b.status
    into v_bill
    from public.bills b
   where b.id = new.bill_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'PAYMENT_BILL_NOT_FOUND';
  end if;

  if new.method <> 'cash' then
    raise exception using
      errcode = 'P0001',
      message = 'PAYMENT_METHOD_NOT_SUPPORTED';
  end if;

  if new.currency_code <> v_bill.currency_code then
    raise exception using
      errcode = 'P0001',
      message = 'PAYMENT_CURRENCY_MISMATCH';
  end if;

  -- Validate every payment row, not only completed rows, so partial-amount
  -- records cannot be introduced under a different status.
  if new.amount_due_minor <> v_bill.grand_total_minor then
    raise exception using
      errcode = 'P0001',
      message = 'PAYMENT_AMOUNT_INVALID';
  end if;

  if new.status = 'completed' and v_bill.status <> 'finalized' then
    raise exception using
      errcode = 'P0001',
      message = 'PAYMENT_BILL_NOT_FINALIZED';
  end if;

  return new;
end;
$$;

create or replace function private.prevent_audit_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'AUDIT_APPEND_ONLY';
end;
$$;

create or replace function private.prevent_audit_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'AUDIT_APPEND_ONLY';
end;
$$;

revoke all on function private.set_updated_at() from public;
revoke all on function private.validate_iana_timezone() from public;
revoke all on function private.validate_role_scope() from public;
revoke all on function private.guard_bill_immutability() from public;
revoke all on function private.guard_order_snapshot() from public;
revoke all on function private.guard_order_item_snapshot() from public;
revoke all on function private.guard_order_item_modifier_immutability() from public;
revoke all on function private.guard_payment_amounts() from public;
revoke all on function private.validate_payment_full_settlement() from public;
revoke all on function private.prevent_audit_mutation() from public;
revoke all on function private.prevent_audit_truncate() from public;

comment on function private.set_updated_at() is
  'Maintains updated_at for mutable database-foundation tables.';

comment on function private.validate_iana_timezone() is
  'Rejects branch timezones that are not present in PostgreSQL IANA timezone names.';

comment on function private.validate_role_scope() is
  'Enforces the five initial role/scope combinations. Does not enforce the last-owner invariant; Agent 2 must do that.';

comment on function private.guard_bill_immutability() is
  'Blocks changes to finalized bill financial and tenant snapshot fields. Status and later-lifecycle fields are intentionally left to Agent 2.';

comment on function private.guard_order_snapshot() is
  'Blocks changes to submitted order tenant and financial snapshot fields.';

comment on function private.guard_order_item_snapshot() is
  'Blocks changes to historical order-item snapshots after submission.';

comment on function private.guard_order_item_modifier_immutability() is
  'Order-item modifier snapshots are append-only.';

comment on function private.guard_payment_amounts() is
  'Blocks changes to recorded payment financial fields. Status and void lifecycle transitions are owned by Agent 2.';

comment on function private.validate_payment_full_settlement() is
  'Validates that a completed payment matches the finalized bill total and currency. Does not implement void or reopen transitions.';

comment on function private.prevent_audit_mutation() is
  'Audit rows are append-only. INSERT is intentionally allowed.';

comment on function private.prevent_audit_truncate() is
  'Audit tables cannot be truncated through normal application operations.';
