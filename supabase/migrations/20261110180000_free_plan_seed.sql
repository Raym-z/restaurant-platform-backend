-- M4.7.2: Deterministic Free plan seed.
--
-- `register_organization` requires an active Free plan row. The catalog was
-- intentionally left empty until plan definitions were approved, which makes a
-- clean deployment unable to complete organization registration.
--
-- This seed is idempotent and conservative:
--   * It inserts only when no active Free plan exists.
--   * It never updates or deletes an existing plan.
--   * It uses the minimum non-zero branch limit (1) rather than inventing a
--     broad entitlement. The final commercial branch limit remains a product
--     decision recorded in docs/m4-7-2-staff-provisioning-implementation.md.
--
-- Apply this migration only with the same approval as the rest of the M4.7.2
-- deployment. It is not applied to hosted Development by this milestone.

insert into public.plans (code, name, is_free, branch_limit, is_active)
select 'free', 'Free', true, 1, true
where not exists (
  select 1
    from public.plans p
   where p.is_free
     and p.is_active
)
on conflict (code) do nothing;
