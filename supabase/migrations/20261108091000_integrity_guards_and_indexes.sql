-- Cross-cutting integrity guards and schema documentation.

create trigger orders_guard_snapshot
  before update on public.orders
  for each row execute function private.guard_order_snapshot();

create trigger order_items_guard_snapshot
  before update on public.order_items
  for each row execute function private.guard_order_item_snapshot();

create trigger order_item_modifiers_guard_immutability
  before update or delete on public.order_item_modifiers
  for each row execute function private.guard_order_item_modifier_immutability();

comment on schema public is
  'Exposed Supabase business schema. Every table has RLS enabled and client grants revoked by the database foundation; Agent 2 adds reviewed policies and grants.';

comment on column public.orders.subtotal_minor is
  'Order-level subtotal snapshot. Agent 2 must calculate and supply it at submission; it is immutable after insert.';

comment on index public.staff_role_assignments_one_active_owner is
  'At most one active Owner per organization. Agent 2 must enforce that an organization cannot lose its last active Owner through role revocation, staff deactivation, or account operations.';

comment on column public.bills.replacement_bill_id is
  'Optional link from a voided unpaid bill to its replacement. Composite FK requires the same organization, branch, and dining session. Reopening workflow is deferred to Agent 2.';

comment on column public.orders.current_bill_id is
  'Optional current-bill pointer. Composite FK requires the bill to belong to the same organization, branch, and dining session. Agent 2 manages assignment/clearing.';
