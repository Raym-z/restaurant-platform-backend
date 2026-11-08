-- Backend-services RLS policies and client grants.
--
-- Writes are intentionally RPC-only except for the approved low-risk customer
-- self-profile update. Guest access is mediated by service-role Edge Functions
-- and scoped RPCs; anonymous clients receive no table grants.

grant usage on schema public to authenticated;

-- Reference data: authenticated staff may read stable lookup tables.
grant select on public.currencies to authenticated;
grant select on public.plans to authenticated;
grant select on public.plan_entitlements to authenticated;
grant select on public.organization_roles to authenticated;

create policy currencies_select_authenticated
  on public.currencies for select to authenticated using (true);
create policy plans_select_authenticated
  on public.plans for select to authenticated using (true);
create policy plan_entitlements_select_authenticated
  on public.plan_entitlements for select to authenticated using (true);
create policy organization_roles_select_authenticated
  on public.organization_roles for select to authenticated using (true);

-- Tenant root and branches.
grant select on public.organizations to authenticated;
grant select on public.branches to authenticated;
grant select on public.subscriptions to authenticated;
grant select on public.subscription_events to authenticated;

create policy organizations_select_staff
  on public.organizations for select to authenticated
  using (id = authz.current_organization_id());

create policy branches_select_staff
  on public.branches for select to authenticated
  using (authz.has_branch_access(id));

create policy subscriptions_select_org_admin
  on public.subscriptions for select to authenticated
  using (
    organization_id = authz.current_organization_id()
    and authz.is_org_admin()
  );

create policy subscription_events_select_org_admin
  on public.subscription_events for select to authenticated
  using (
    organization_id = authz.current_organization_id()
    and authz.is_org_admin()
  );

-- Staff and access data. Branch-scoped managers do not gain staff visibility
-- because that permission is not approved.
grant select on public.staff_profiles to authenticated;
grant select on public.staff_role_assignments to authenticated;
grant select on public.staff_branch_assignments to authenticated;
grant select on public.platform_admins to authenticated;

create policy staff_profiles_select_self_or_org_admin
  on public.staff_profiles for select to authenticated
  using (authz.can_view_staff(id));

create policy staff_role_assignments_select_self_or_org_admin
  on public.staff_role_assignments for select to authenticated
  using (
    staff_id = authz.current_staff_id()
    or (
      organization_id = authz.current_organization_id()
      and authz.is_org_admin()
    )
  );

create policy staff_branch_assignments_select_self_or_org_admin
  on public.staff_branch_assignments for select to authenticated
  using (
    staff_id = authz.current_staff_id()
    or (
      organization_id = authz.current_organization_id()
      and authz.is_org_admin()
    )
  );

create policy platform_admins_select_self
  on public.platform_admins for select to authenticated
  using (auth_user_id = auth.uid());

-- Customer self-service: own profile read and approved low-risk update.
grant select on public.customer_profiles to authenticated;
grant update (full_name, phone, updated_at) on public.customer_profiles to authenticated;

create policy customer_profiles_select_own
  on public.customer_profiles for select to authenticated
  using (auth_user_id = auth.uid() and deleted_at is null);

create policy customer_profiles_update_own
  on public.customer_profiles for update to authenticated
  using (auth_user_id = auth.uid() and deleted_at is null)
  with check (auth_user_id = auth.uid() and deleted_at is null);

-- Menu and charge configuration. Organization-owned rows are readable by all
-- active staff in the organization; branch rows require branch access.
grant select on public.menu_categories to authenticated;
grant select on public.menu_items to authenticated;
grant select on public.modifier_groups to authenticated;
grant select on public.modifier_options to authenticated;
grant select on public.menu_item_modifier_groups to authenticated;
grant select on public.branch_menu_categories to authenticated;
grant select on public.branch_menu_items to authenticated;
grant select on public.organization_charge_configurations to authenticated;
grant select on public.branch_charge_configurations to authenticated;

create policy menu_categories_select_org_member
  on public.menu_categories for select to authenticated
  using (organization_id = authz.current_organization_id());

create policy menu_items_select_org_member
  on public.menu_items for select to authenticated
  using (organization_id = authz.current_organization_id());

create policy modifier_groups_select_org_member
  on public.modifier_groups for select to authenticated
  using (organization_id = authz.current_organization_id());

create policy modifier_options_select_org_member
  on public.modifier_options for select to authenticated
  using (organization_id = authz.current_organization_id());

create policy menu_item_modifier_groups_select_org_member
  on public.menu_item_modifier_groups for select to authenticated
  using (organization_id = authz.current_organization_id());

create policy branch_menu_categories_select_branch
  on public.branch_menu_categories for select to authenticated
  using (authz.has_branch_access(branch_id));

create policy branch_menu_items_select_branch
  on public.branch_menu_items for select to authenticated
  using (authz.has_branch_access(branch_id));

create policy organization_charge_configurations_select_org_member
  on public.organization_charge_configurations for select to authenticated
  using (organization_id = authz.current_organization_id());

create policy branch_charge_configurations_select_branch
  on public.branch_charge_configurations for select to authenticated
  using (authz.has_branch_access(branch_id));

-- Tables and dining sessions.
grant select on public.restaurant_tables to authenticated;
grant select on public.table_qr_identifiers to authenticated;
grant select on public.dining_sessions to authenticated;

create policy restaurant_tables_select_branch
  on public.restaurant_tables for select to authenticated
  using (authz.has_branch_access(branch_id));

create policy table_qr_identifiers_select_branch
  on public.table_qr_identifiers for select to authenticated
  using (authz.has_branch_access(branch_id));

create policy dining_sessions_select_branch
  on public.dining_sessions for select to authenticated
  using (authz.has_branch_access(branch_id));

-- Orders are visible to active staff assigned to the branch.
grant select on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select on public.order_item_modifiers to authenticated;

create policy orders_select_branch
  on public.orders for select to authenticated
  using (authz.has_branch_access(branch_id));

create policy order_items_select_branch
  on public.order_items for select to authenticated
  using (authz.has_branch_access(branch_id));

create policy order_item_modifiers_select_branch
  on public.order_item_modifiers for select to authenticated
  using (
    exists (
      select 1
      from public.order_items oi
      where oi.id = order_item_modifiers.order_item_id
        and authz.has_branch_access(oi.branch_id)
    )
  );

-- Billing and payment reads are limited to documented financial roles.
grant select on public.session_discounts to authenticated;
grant select on public.bills to authenticated;
grant select on public.bill_orders to authenticated;
grant select on public.bill_discounts to authenticated;
grant select on public.payments to authenticated;

create policy session_discounts_select_billing_roles
  on public.session_discounts for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    )
  );

create policy bills_select_billing_roles
  on public.bills for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    )
  );

create policy bill_orders_select_billing_roles
  on public.bill_orders for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    )
  );

create policy bill_discounts_select_billing_roles
  on public.bill_discounts for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    )
  );

create policy payments_select_billing_roles
  on public.payments for select to authenticated
  using (
    authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager', 'cashier']::text[]
    )
  );

-- Waitlist: customers read their own entries; queue staff roles read branch
-- entries. Cashier/kitchen queue visibility is not approved.
grant select on public.waitlist_entries to authenticated;

create policy waitlist_entries_select_own_or_queue_role
  on public.waitlist_entries for select to authenticated
  using (
    customer_id = authz.current_customer_id()
    or authz.has_branch_role(
      branch_id,
      array['owner', 'admin', 'manager']::text[]
    )
  );

comment on policy customer_profiles_update_own on public.customer_profiles is
  'Approved low-risk direct write: a customer may update only display name, phone, and updated_at on their own profile.';
