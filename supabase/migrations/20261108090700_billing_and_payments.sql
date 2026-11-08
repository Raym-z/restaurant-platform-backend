-- Finalized bills, bill composition, discounts, and cash payments.

create table public.bills (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  dining_session_id uuid not null,
  status public.bill_status not null default 'finalized',
  currency_code text not null
    references public.currencies (code) on delete restrict,
  subtotal_minor bigint not null,
  discount_total_minor bigint not null,
  tax_total_minor bigint not null,
  service_charge_total_minor bigint not null,
  grand_total_minor bigint not null,
  tax_configuration_snapshot jsonb not null default '{}'::jsonb,
  service_charge_configuration_snapshot jsonb not null default '{}'::jsonb,
  finalized_at timestamptz not null default now(),
  finalized_by_staff_id uuid not null,
  settled_at timestamptz,
  voided_at timestamptz,
  voided_by_staff_id uuid,
  void_reason text,
  replacement_bill_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bills_subtotal_check check (subtotal_minor >= 0),
  constraint bills_discount_total_check check (discount_total_minor >= 0),
  constraint bills_tax_total_check check (tax_total_minor >= 0),
  constraint bills_service_charge_total_check check (service_charge_total_minor >= 0),
  constraint bills_grand_total_check check (grand_total_minor >= 0),
  constraint bills_replacement_not_self_check
    check (replacement_bill_id is null or replacement_bill_id <> id),
  constraint bills_id_organization_branch_key
    unique (id, organization_id, branch_id),
  constraint bills_id_organization_branch_session_key
    unique (id, organization_id, branch_id, dining_session_id),
  constraint bills_session_branch_organization_fkey
    foreign key (dining_session_id, branch_id, organization_id)
    references public.dining_sessions (id, branch_id, organization_id)
    on delete restrict,
  constraint bills_finalized_by_organization_fkey
    foreign key (finalized_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint bills_voided_by_organization_fkey
    foreign key (voided_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint bills_replacement_same_tenant_session_fkey
    foreign key (
      replacement_bill_id,
      organization_id,
      branch_id,
      dining_session_id
    )
    references public.bills (
      id,
      organization_id,
      branch_id,
      dining_session_id
    )
    on delete restrict
);

create unique index bills_one_active_per_session
  on public.bills (dining_session_id)
  where status in ('finalized', 'settled');

create unique index bills_one_replacement_per_voided_bill
  on public.bills (replacement_bill_id)
  where replacement_bill_id is not null;

create index bills_branch_status_finalized_idx
  on public.bills (branch_id, status, finalized_at desc);

create index bills_organization_finalized_idx
  on public.bills (organization_id, finalized_at desc);

create trigger bills_guard_immutability
  before update on public.bills
  for each row execute function private.guard_bill_immutability();

create trigger bills_set_updated_at
  before update on public.bills
  for each row execute function private.set_updated_at();

alter table public.orders
  add constraint orders_current_bill_tenant_session_fkey
  foreign key (
    current_bill_id,
    organization_id,
    branch_id,
    dining_session_id
  )
  references public.bills (
    id,
    organization_id,
    branch_id,
    dining_session_id
  )
  on delete restrict;

create table public.bill_orders (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null,
  order_id uuid not null,
  organization_id uuid not null,
  branch_id uuid not null,
  dining_session_id uuid not null,
  order_amount_minor bigint not null,
  created_at timestamptz not null default now(),
  constraint bill_orders_amount_check check (order_amount_minor >= 0),
  constraint bill_orders_bill_order_unique unique (bill_id, order_id),
  constraint bill_orders_bill_tenant_session_fkey
    foreign key (bill_id, organization_id, branch_id, dining_session_id)
    references public.bills (id, organization_id, branch_id, dining_session_id)
    on delete restrict,
  constraint bill_orders_order_tenant_session_fkey
    foreign key (order_id, organization_id, branch_id, dining_session_id)
    references public.orders (id, organization_id, branch_id, dining_session_id)
    on delete restrict
);

create index bill_orders_order_idx
  on public.bill_orders (order_id);

create table public.bill_discounts (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null,
  organization_id uuid not null,
  branch_id uuid not null,
  discount_type public.discount_type not null,
  value_minor bigint,
  percentage_basis_points integer,
  discount_amount_minor bigint not null,
  reason text,
  applied_by_staff_id uuid not null,
  created_at timestamptz not null default now(),
  constraint bill_discounts_amount_check check (discount_amount_minor >= 0),
  constraint bill_discounts_value_check check (
    (
      discount_type = 'fixed_amount'
      and value_minor is not null
      and value_minor >= 0
      and percentage_basis_points is null
    )
    or (
      discount_type = 'percentage'
      and percentage_basis_points is not null
      and percentage_basis_points >= 0
      and value_minor is null
    )
  ),
  constraint bill_discounts_bill_organization_branch_fkey
    foreign key (bill_id, organization_id, branch_id)
    references public.bills (id, organization_id, branch_id)
    on delete restrict,
  constraint bill_discounts_applied_by_organization_fkey
    foreign key (applied_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

create index bill_discounts_bill_idx
  on public.bill_discounts (bill_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  bill_id uuid not null,
  method public.payment_method not null,
  status public.payment_status not null default 'completed',
  currency_code text not null
    references public.currencies (code) on delete restrict,
  amount_due_minor bigint not null,
  cash_received_minor bigint not null,
  change_minor bigint not null,
  recorded_by_staff_id uuid not null,
  paid_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by_staff_id uuid,
  void_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_amount_due_check check (amount_due_minor >= 0),
  constraint payments_cash_received_check check (cash_received_minor >= 0),
  constraint payments_change_check check (change_minor >= 0),
  constraint payments_cash_covers_due_check
    check (cash_received_minor >= amount_due_minor),
  constraint payments_change_arithmetic_check
    check (change_minor = cash_received_minor - amount_due_minor),
  constraint payments_bill_organization_branch_fkey
    foreign key (bill_id, organization_id, branch_id)
    references public.bills (id, organization_id, branch_id)
    on delete restrict,
  constraint payments_recorded_by_organization_fkey
    foreign key (recorded_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict,
  constraint payments_voided_by_organization_fkey
    foreign key (voided_by_staff_id, organization_id)
    references public.staff_profiles (id, organization_id)
    on delete restrict
);

-- Initial release: at most one successful full-settlement payment per bill.
-- This index must be removed if a future release approves partial payments.
create unique index payments_one_completed_per_bill
  on public.payments (bill_id)
  where status = 'completed';

create index payments_branch_paid_at_idx
  on public.payments (branch_id, paid_at desc);

create index payments_bill_idx
  on public.payments (bill_id);

create trigger payments_validate_full_settlement
  before insert or update of status, bill_id, method, currency_code,
    amount_due_minor, cash_received_minor, change_minor
  on public.payments
  for each row execute function private.validate_payment_full_settlement();

create trigger payments_guard_amounts
  before update on public.payments
  for each row execute function private.guard_payment_amounts();

create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function private.set_updated_at();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'bills',
    'bill_orders',
    'bill_discounts',
    'payments'
  ]
  loop
    execute format('alter table public.%I enable row level security', table_name);

    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on public.%I from anon', table_name);
    end if;

    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on public.%I from authenticated', table_name);
    end if;
  end loop;
end
$$;

comment on table public.bills is
  'Finalized bills are frozen financial records. Reopen is proposed as void-and-replace; the full lifecycle is owned by Agent 2.';

comment on column public.bills.replacement_bill_id is
  'Composite FK requires the replacement bill to share organization, branch, and dining session. No reopen workflow is implemented here.';

comment on column public.orders.current_bill_id is
  'Operational pointer to the current bill. Composite FK enforces same organization, branch, and dining session. Agent 2 manages set/clear.';

comment on table public.payments is
  'Initial release supports one completed full-settlement cash payment per bill. Payment void and correction lifecycle is deferred to Agent 2.';

comment on index public.payments_one_completed_per_bill is
  'Initial-release invariant. Drop only if a future approved release introduces partial payments.';
