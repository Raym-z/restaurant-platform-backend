-- Local development seed entry point.
--
-- Supabase applies this file after migrations during `supabase db reset`.
-- Approved reference data is also seeded by migrations so non-reset
-- deployments receive it. This file is intentionally idempotent.
--
-- Do not add demo organizations, auth users, transactional data, plans, or
-- permission mappings here until those catalogs are approved. Synthetic test
-- fixtures are owned by the testing-infrastructure workstream.

insert into public.currencies (code, name, minor_unit_exponent)
values ('IDR', 'Indonesian Rupiah', 0)
on conflict (code) do nothing;

insert into public.organization_roles (code, name, description)
values
  ('owner', 'Owner', 'Organization-wide authority. Exactly one active Owner per organization.'),
  ('admin', 'Admin', 'Organization administration; scope is explicit (organization-wide or assigned branches).'),
  ('manager', 'Manager', 'Operational management within assigned branches.'),
  ('cashier', 'Cashier', 'Cashier and payment workflows within assigned branches.'),
  ('kitchen_staff', 'Kitchen Staff', 'Kitchen and preparation workflows within assigned branches.')
on conflict (code) do nothing;
