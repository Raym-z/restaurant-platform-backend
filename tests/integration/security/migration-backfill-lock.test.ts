import { randomUUID } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

import pg from "pg";
import { describe, expect, it } from "vitest";

import { localDbUrl } from "../setup/env.js";

const { Client } = pg;

const migrationsDir = path.join(process.cwd(), "supabase", "migrations");
const targetMigration = "20261108120000_m2_branch_scoped_staff_roles.sql";

const authShimSql = `
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid;
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  );
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;
`;

const sleep = async (milliseconds: number): Promise<void> => {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
};

const waitForShareLock = async (
  observer: pg.Client,
  pid: number,
): Promise<void> => {
  for (let attempt = 0; attempt < 600; attempt += 1) {
    const result = await observer.query<{ present: boolean }>(
      `select exists (
         select 1
         from pg_locks
         where pid = $1
           and locktype = 'relation'
           and relation = 'public.staff_branch_assignments'::regclass
           and mode = 'ShareLock'
           and granted
       ) as present`,
      [pid],
    );

    if (result.rows[0]!.present) {
      return;
    }

    await sleep(20);
  }

  throw new Error("Timed out waiting for the migration SHARE lock");
};

const waitForBlockedBy = async (
  observer: pg.Client,
  pid: number,
  blockerPid: number,
): Promise<boolean> => {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    const result = await observer.query<{
      wait_event_type: string | null;
      blockers: number[];
    }>(
      `select wait_event_type, pg_blocking_pids(pid) as blockers
         from pg_stat_activity
        where pid = $1`,
      [pid],
    );
    const row = result.rows[0];

    if (row?.wait_event_type === "Lock" && row.blockers.includes(blockerPid)) {
      return true;
    }

    await sleep(10);
  }

  return false;
};

const backendPid = async (client: pg.Client): Promise<number> => {
  const result = await client.query<{ pid: number }>(
    "select pg_backend_pid() as pid",
  );
  return result.rows[0]!.pid;
};

describe("migration 120000 backfill locking", () => {
  // The full migration-path test requires CREATEDB (the local Supabase postgres
  // role normally has it). Set M21_SKIP_MIGRATION_DB_TEST=1 only when the
  // environment intentionally cannot provide a disposable database; report the
  // skip explicitly rather than pretending the migration path passed.
  const disabled = process.env.M21_SKIP_MIGRATION_DB_TEST === "1";

  it.skipIf(disabled)(
    "applies the real migration while its SHARE lock blocks a concurrent branch-assignment insert",
    async () => {
      const testDbUrl = localDbUrl();
      const databaseName = `m21_migration_${randomUUID().replaceAll("-", "")}`;
      const admin = new Client({ connectionString: testDbUrl });
      await admin.connect();

      let migration: pg.Client | undefined;
      let writer: pg.Client | undefined;
      let observer: pg.Client | undefined;

      try {
        try {
          await admin.query(`create database ${databaseName}`);
        } catch (error) {
          if ((error as { code?: string }).code === "42501") {
            throw new Error(
              "The migration-path test requires CREATEDB. Run it against a disposable PostgreSQL superuser, or set M21_SKIP_MIGRATION_DB_TEST=1 and record the migration-path test as outstanding.",
            );
          }
          throw error;
        }

        const tempUrl = new URL(testDbUrl);
        tempUrl.pathname = `/${databaseName}`;
        const connectionString = tempUrl.toString();

        migration = new Client({ connectionString });
        writer = new Client({ connectionString });
        observer = new Client({ connectionString });
        await Promise.all([
          migration.connect(),
          writer.connect(),
          observer.connect(),
        ]);

        await migration.query(authShimSql);

        const migrationFiles = readdirSync(migrationsDir)
          .filter(
            (name) => name.endsWith(".sql") && name < targetMigration,
          )
          .sort((left, right) => left.localeCompare(right));

        for (const file of migrationFiles) {
          await migration.query(
            readFileSync(path.join(migrationsDir, file), "utf8"),
          );
        }

        const organizationId = randomUUID();
        const branchA = randomUUID();
        const branchB = randomUUID();
        const legacyAuthUserId = randomUUID();
        const writerAuthUserId = randomUUID();
        const legacyStaffId = randomUUID();
        const writerStaffId = randomUUID();

        await migration.query(
          `insert into auth.users (id) values ($1), ($2)`,
          [legacyAuthUserId, writerAuthUserId],
        );

        await migration.query(
          `insert into public.organizations (id, name, default_currency_code)
           values ($1, 'Migration backfill test', 'IDR')`,
          [organizationId],
        );

        await migration.query(
          `insert into public.branches (id, organization_id, name, timezone)
           values ($1, $2, 'Branch A', 'UTC'), ($3, $2, 'Branch B', 'UTC')`,
          [branchA, organizationId, branchB],
        );

        await migration.query(
          `insert into public.staff_profiles
             (id, auth_user_id, organization_id, display_name, status, activated_at)
           values
             ($1, $2, $3, 'Legacy staff', 'active', now()),
             ($4, $5, $3, 'Writer staff', 'active', now())`,
          [
            legacyStaffId,
            legacyAuthUserId,
            organizationId,
            writerStaffId,
            writerAuthUserId,
          ],
        );

        await migration.query(
          `insert into public.staff_branch_assignments
             (staff_id, organization_id, branch_id)
           values ($1, $2, $3)`,
          [legacyStaffId, organizationId, branchA],
        );

        await migration.query(
          `insert into public.staff_role_assignments
             (staff_id, organization_id, role_code, scope_type)
           values ($1, $2, 'manager', 'branch')`,
          [legacyStaffId, organizationId],
        );

        // Slow the backfill after the migration acquires its SHARE lock so the
        // concurrent insert can be observed deterministically. The trigger is
        // created before the branch_id column exists; to_jsonb keeps it valid.
        await migration.query(`
          create or replace function private.test_slow_m21_backfill()
          returns trigger
          language plpgsql
          as $$
          begin
            if (to_jsonb(old)->>'branch_id') is null
               and (to_jsonb(new)->>'branch_id') is not null then
              perform pg_sleep(2);
            end if;
            return new;
          end;
          $$;

          create trigger test_slow_m21_backfill
            before update on public.staff_role_assignments
            for each row execute function private.test_slow_m21_backfill();
        `);

        const migrationPid = await backendPid(migration);
        const writerPid = await backendPid(writer);

        const migrationPromise = migration.query(
          readFileSync(path.join(migrationsDir, targetMigration), "utf8"),
        );

        await waitForShareLock(observer, migrationPid);

        const writePromise = writer.query(
          `insert into public.staff_branch_assignments
             (staff_id, organization_id, branch_id)
           values ($1, $2, $3)`,
          [writerStaffId, organizationId, branchB],
        );

        expect(await waitForBlockedBy(observer, writerPid, migrationPid)).toBe(
          true,
        );

        await migrationPromise;
        await writePromise;

        const backfilled = await observer.query<{ branch_id: string | null }>(
          `select branch_id
             from public.staff_role_assignments
            where staff_id = $1
              and role_code = 'manager'`,
          [legacyStaffId],
        );
        expect(backfilled.rows[0]!.branch_id).toBe(branchA);

        const writerAssignment = await observer.query<{ count: string }>(
          `select count(*)::text as count
             from public.staff_branch_assignments
            where staff_id = $1
              and branch_id = $2
              and revoked_at is null`,
          [writerStaffId, branchB],
        );
        expect(Number(writerAssignment.rows[0]!.count)).toBe(1);
      } finally {
        await migration?.end().catch(() => undefined);
        await writer?.end().catch(() => undefined);
        await observer?.end().catch(() => undefined);
        await admin
          .query(`drop database if exists ${databaseName} with (force)`)
          .catch(() => undefined);
        await admin.end().catch(() => undefined);
      }
    },
    60_000,
  );
});
