# Implementation Roadmap

## 1. Overview

Implement the backend in dependency order. Each phase should be reviewed and tested before dependent application features rely on it. This roadmap is a proposed sequence, not authorization to begin destructive or production changes.

## 2. Phases

### Phase 1: Repository and environment foundation
- Verify repository structure and Supabase tooling.
- Establish development/staging/production configuration conventions.
- Add safe environment templates.
- Configure migration and test workflows.
- Document local development and deployment procedures.

**Outcome:** Reproducible backend development foundation.

### Phase 2: Domain model and architecture approval
- Finalize organization and branch model.
- Finalize staff identity and membership structure.
- Define customer identity.
- Define menus, tables, dining sessions, orders, payments, and queue concepts.
- Resolve lifecycle and uniqueness rules.
- Review the conceptual ERD with all application requirements.

**Outcome:** Approved data model before SQL implementation.

### Phase 3: Core database schema
- Implement foundational organization, branch, identity/membership, role, and permission structures.
- Add constraints, indexes, and migration tests.
- Add seed data for development.

**Outcome:** Reliable tenant and identity foundation.

### Phase 4: Authentication, authorization, and RLS
- Implement staff and customer access boundaries.
- Implement role and branch authorization helpers where appropriate.
- Enable and test RLS.
- Test cross-tenant denial paths.
- Review privileged function grants.

**M2.1 implementation note:** staff role assignments are branch-aware. A role
row is either organization-scoped with no branch, or branch-scoped with one
branch. The same staff member may hold different roles at different branches.
Legacy branch-scoped rows are deterministically split across their active
branch assignments before the new uniqueness and check constraints are
enforced. The five canonical roles and the one-active-Owner invariant are
unchanged.

A follow-up migration, `20261109120000_m2_branch_scoped_staff_roles_fixes.sql`,
makes the branch-assignment consistency trigger conflict-safe for concurrent
grants, serializes concurrent revocations, adds the branch/organization FK
index, and removes unnecessary execute grants on internal helpers. Branch
assignment revocation is a suspension: re-assigning the branch restores an
otherwise active branch-scoped role. Permanent removal requires revoking the
role. See `docs/schema/database-foundation.md` §5 for preflight, locking,
backup, and recovery guidance for the one-way legacy backfill.

**Outcome:** Secure access foundation.

### Phase 5: Restaurant configuration
- Implement menus, categories, items, tables, and branch configuration.
- Define branch-specific menu availability/pricing rules.
- Add approved access contracts.

**Outcome:** Applications can configure restaurant operations.

### Phase 6: Dining sessions and QR tokens
- Implement session lifecycle.
- Implement secure token creation, hashing, resolution, rotation, and revocation.
- Enforce expiry and closed-session rejection.
- Test public access boundaries.

**Outcome:** Secure QR session foundation.

### Phase 7: Orders and KDS contracts
- Implement order and order-item persistence.
- Define validation and status transitions.
- Implement idempotent order submission.
- Define realtime notifications and recovery requirements.
- Test POS/ordering/KDS integration.

**Outcome:** Shared order lifecycle.

### Phase 8: Cash payments
- Implement cash payment recording.
- Validate received amount against outstanding balance.
- Calculate change.
- Define payment status and correction rules.
- Add idempotency and audit controls.
- Test duplicate and unauthorized operations.

**Outcome:** Cash-only payment workflow. No payment gateway or online payment integration.

### Phase 9: Waitlist
- Implement customer queue records and lifecycle.
- Enforce duplicate-entry rules.
- Define customer self-service access.
- Define staff queue operations and optional location verification.
- Test POS/waitlist integration.

**Outcome:** Shared waitlist functionality.

### Phase 10: Subscription and entitlements
- Define plans, limits, subscription status, and feature entitlements.
- Enforce entitlements in trusted backend operations.
- Defer external billing-provider integration unless separately approved.

**Outcome:** Backend subscription enforcement.

### Phase 11: Hardening and production readiness
- Run database, RLS, integration, and security tests.
- Validate migration procedures.
- Document backup and restore.
- Configure monitoring and operational alerts.
- Review secrets and production access.
- Verify all three application integrations.

**Outcome:** Production-ready shared backend.

## 3. Delivery principles

- Approve the data model before creating domain migrations.
- Build tenant isolation before exposing business data.
- Define contracts before application teams depend on them.
- Make migrations reproducible and reviewable.
- Test denied access as carefully as permitted access.
- Coordinate changes with every consuming repository.
- Keep each implementation task small and independently testable.

## 4. Initial release boundaries

- One shared Supabase project per environment.
- Separate staff and customer identity domains.
- Guest QR ordering.
- Branch-scoped waitlist.
- Secure dining-session QR tokens.
- Cash payments only.
- No payment gateway, card, e-wallet, or online payment integration in the initial release.
