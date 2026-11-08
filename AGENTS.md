# AGENTS.md — Restaurant Platform Backend

## 1. Purpose
This repository is the shared backend source of truth for a multi-tenant restaurant SaaS platform. It owns database structures, migrations, database security, shared backend logic, and integration contracts.

The platform has four repositories:
- `restaurant-pos`: staff-facing POS, restaurant administration, cashier workflows, and KDS.
- `restaurant-ordering`: public guest QR-ordering application.
- `restaurant-waitlist`: customer accounts and public waitlist application.
- `restaurant-platform-backend`: shared backend infrastructure.

All applications use one shared Supabase project per environment.

## 2. Repository ownership
This repository owns:
- PostgreSQL schema, relationships, constraints, indexes, and migrations.
- Row Level Security (RLS) policies.
- Database functions and RPCs.
- Supabase Edge Functions and shared server-side business rules.
- Supabase Storage configuration and policies.
- Shared types and integration contracts.
- Realtime authorization/configuration.
- Seed data, database tests, and backend documentation.

Application repositories must not create competing copies of shared schema, migrations, or backend business rules.

## 3. Architecture principles
- Multi-tenant hierarchy: Platform → Organization → Branch.
- Organization-owned records must be scoped to the correct organization.
- Branch-specific records must be scoped to the correct branch.
- Staff and customer identities are separate authorization domains.
- PostgreSQL is the authoritative source for persisted data.
- Backend authorization is mandatory; frontend checks are supplementary.
- Public QR access never grants staff access.
- Prefer least privilege and deny access by default.

## 4. Technology
The intended infrastructure is Supabase, PostgreSQL, Supabase Auth, Storage, Realtime, Edge Functions, SQL, and TypeScript where appropriate. Existing project configuration is authoritative. Do not add frameworks or services without documenting the need and obtaining approval.

## 5. Database and migration rules
- Every schema change must be represented by a reviewed SQL migration in this repository.
- Follow the established migration naming and ordering convention.
- Inspect existing migrations before creating a new one.
- Include appropriate foreign keys, constraints, indexes, and defaults.
- Avoid destructive or irreversible changes unless explicitly approved.
- Do not silently edit an already-applied migration; create a follow-up migration.
- Test migrations against a disposable or development database before production.
- Coordinate schema changes with every affected application.
- Never rely on undocumented manual production database changes.

## 6. RLS and authorization
- Enable RLS on applicable exposed tables.
- Define explicit policies for required operations.
- Validate identity, organization membership, role/permission, and branch assignment as applicable.
- Never trust client-supplied organization or branch IDs as proof of access.
- Test both permitted and denied access paths.
- Review policies whenever table relationships or authorization rules change.
- Do not disable RLS to work around an application problem.

## 7. Authentication boundaries
**Staff:** authenticated through the staff flow used by POS; access is limited by organization membership, role, permissions, and branch assignments.

**Customers:** platform-wide customer accounts used by the waitlist application; customer identity does not grant staff privileges.

**Guest ordering:** the ordering application supports guest ordering through a valid dining-session QR token; it does not require a customer account.

Do not merge staff and customer authorization into one permission model.

## 8. Backend operations and contracts
Before implementing an RPC, Edge Function, or other shared operation, document its purpose, caller, authentication requirements, authorization rules, request/response shape, validation, errors, and idempotency behavior where relevant. Shared contracts must be maintained here or generated from an approved source.

Sensitive rules—including order validation, session validity, queue transitions, cash payment recording, and subscription entitlements—must be enforced server-side.

## 9. Realtime
- Persisted database records remain authoritative.
- Realtime events notify clients of changes; they are not the source of truth.
- Subscriptions must be restricted to authorized organizations and branches.
- Avoid unnecessary sensitive data in event payloads.
- Clients must recover by fetching current persisted state after reconnecting.
- Design consumers to tolerate duplicate, delayed, or missed notifications.

## 10. Payment scope
The initial release supports **cash payments only**:
- Record the amount received.
- Validate it against the outstanding order balance.
- Calculate change.
- Persist payment records against the correct order, organization, and branch.
- Protect payment recording, correction, and cancellation with authorization and auditability.

Do not implement payment gateways, online payments, cards, or e-wallets in the initial release.

## 11. Security and secrets
- Treat all client input as untrusted.
- Never expose Supabase service-role keys or other privileged credentials to browser code.
- Keep real secrets out of Git; use environment variables and safe `.env.example` placeholders.
- Use cryptographically secure, unguessable dining-session tokens; store token hashes rather than raw tokens where applicable.
- Apply suitable rate limits to public operations.
- Do not log passwords, raw tokens, or unnecessary personal information.
- Validate and authorize sensitive operations on the server.

## 12. Coding and testing standards
- Prefer modular, readable, maintainable implementations.
- Use TypeScript for applicable server-side logic; avoid `any` without a documented reason.
- Use descriptive names and explicit error handling.
- Add tests for business rules, constraints, authorization, and RLS.
- Validate migration behavior and rollback/recovery implications.
- Do not add abstractions without a concrete benefit.

## 13. Git and agent coordination
- Do not commit directly to `main`.
- Work only on the assigned branch/worktree.
- Keep changes focused and commits descriptive.
- Do not modify unrelated files or overwrite another agent's uncommitted work.
- Coordinate shared migrations and contracts before implementation.
- Avoid concurrent agents editing the same migration or schema definition.

## 14. Required workflow
Before a task:
1. Read this file and relevant documentation.
2. Inspect the current schema, migrations, and existing implementation.
3. Identify affected applications and dependencies.
4. Confirm business rules and authorization implications.
5. Propose the contract/schema change before implementing ambiguous behavior.

After a task:
1. Run relevant tests and checks.
2. Test authorized and unauthorized access.
3. Verify migration consistency.
4. Update affected documentation and shared types.
5. Report changed files, tests run, and unresolved risks.

## 15. Restrictions
Do not invent undocumented contracts, bypass RLS, duplicate shared schemas, expose privileged credentials, introduce payment gateways in the initial release, or make destructive database changes without explicit approval. Ask for clarification when requirements are ambiguous.
