# Restaurant Platform Backend

Shared backend infrastructure for a multi-tenant Restaurant SaaS platform.

This repository is the source of truth for the platform's database, migrations, authorization policies, shared backend logic, and integration contracts.

## Platform repositories

| Repository | Responsibility |
|---|---|
| `restaurant-pos` | Staff-facing POS, restaurant management, cashier operations, and Kitchen Display System. |
| `restaurant-ordering` | Public guest QR-ordering application. |
| `restaurant-waitlist` | Customer accounts and public waitlist application. |
| `restaurant-platform-backend` | Shared database, backend logic, security policies, and contracts. |

All applications use one shared Supabase project per environment.

## Responsibilities

- PostgreSQL schema, relationships, constraints, and indexes.
- SQL migrations.
- Row Level Security (RLS).
- Database functions and RPCs.
- Supabase Edge Functions.
- Supabase Auth configuration and authorization rules.
- Supabase Storage configuration and policies.
- Realtime configuration and access control.
- Shared TypeScript types and integration contracts.
- Seed data, database tests, and backend documentation.

## Technology

- Supabase
- PostgreSQL
- Supabase Auth
- Supabase Storage
- Supabase Realtime
- Supabase Edge Functions
- SQL and TypeScript where appropriate

The actual project configuration is authoritative. Do not assume a package, framework, or deployment tool is installed until verified.

## Core model

The platform follows the hierarchy:

`Platform → Organization → Branch`

Organizations represent independent restaurant businesses and may operate multiple branches. Staff access is scoped by organization membership, role, permissions, and branch assignments. Customer identity is separate from staff identity.

## Initial business scope

The backend will support organizations, branches, staff, roles and permissions, customer accounts, menus, tables, dining sessions, QR tokens, orders, order items, cash payments, waitlist entries, subscriptions, and operational reporting data.

### Payment scope

The initial release supports **cash payments only**. The system records the amount received, calculates change, and tracks payment status. Payment gateways, card payments, e-wallets, and online payment processing are out of scope for the initial release.

## Documentation

| File | Purpose |
|---|---|
| `AGENTS.md` | Instructions and constraints for coding agents. |
| `docs/system-overview.md` | Backend responsibilities and repository interactions. |
| `docs/database-architecture.md` | PostgreSQL/Supabase architecture and migration strategy. |
| `docs/data-model.md` | Domain entities, relationships, and business rules. |
| `docs/authentication-and-authorization.md` | Staff/customer identity and authorization. |
| `docs/row-level-security.md` | RLS strategy and tenant isolation. |
| `docs/api-and-rpc-contracts.md` | Shared API, RPC, and Edge Function contracts. |
| `docs/realtime-architecture.md` | Events, subscriptions, and recovery behavior. |
| `docs/security-guidelines.md` | Backend security requirements. |
| `docs/implementation-roadmap.md` | Recommended implementation sequence. |
| `docs/backend-services.md` | RLS, authorization helpers, RPCs, Edge Functions, and service blockers. |
| `docs/m3-core-pos-operations.md` | M3 tables, dining sessions, orders, state machine, and RPC contracts. |
| `docs/m4-7-2-staff-provisioning-implementation.md` | Staff invitation architecture, migration, tests, and hosted configuration. |

## Development status

**Current stage: architecture and documentation.**

The schema, migrations, API contracts, and implementation should be developed after the domain model and business rules have been reviewed and agreed upon.

## Security

Never commit real credentials or expose privileged Supabase keys. All shared database changes must be managed through reviewed migrations. See `AGENTS.md` and the security documentation for detailed requirements.
