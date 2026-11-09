import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  analyzeSql,
  findDestructiveStatements,
  findPrivateGrantViolations,
  findSecurityIssues,
} from '../../scripts/lib/sql-scan.mjs';

function rules(findings) {
  return findings.map((finding) => finding.rule);
}

describe('migration scanner: TRUNCATE trigger declarations', () => {
  it('does not flag BEFORE TRUNCATE trigger declarations', () => {
    const sql = `
      create trigger audit_events_prevent_truncate
        before truncate on public.audit_events
        for each statement execute function private.prevent_audit_truncate();
    `;
    expect(findDestructiveStatements(sql)).toEqual([]);
  });

  it('does not flag multi-event trigger declarations containing TRUNCATE', () => {
    const sql = `
      create trigger audit_events_guard
        before update or delete or truncate on public.audit_events
        for each statement execute function private.prevent_audit_mutation();
    `;
    expect(findDestructiveStatements(sql)).toEqual([]);
  });

  it('still flags a real TRUNCATE TABLE statement', () => {
    const findings = findDestructiveStatements(
      'truncate table public.audit_events;',
    );
    expect(rules(findings)).toContain('TRUNCATE');
  });

  it('still flags a plain TRUNCATE statement without TABLE', () => {
    const findings = findDestructiveStatements(
      'truncate public.audit_events restart identity cascade;',
    );
    expect(rules(findings)).toContain('TRUNCATE');
  });

  it('does not flag the word TRUNCATE inside a prose comment string', () => {
    const sql = `
      comment on table public.audit_events is
        'Central audit history. UPDATE, DELETE, and TRUNCATE are blocked.';
    `;
    expect(findDestructiveStatements(sql)).toEqual([]);
  });

  it('flags dynamic SQL that starts with a destructive statement', () => {
    const sql = `
      do $$
      begin
        execute 'truncate table public.audit_events';
      end
      $$;
    `;
    expect(rules(findDestructiveStatements(sql))).toContain('DYNAMIC TRUNCATE');
  });

  it('flags a destructive statement later in a dynamic SQL string', () => {
    const sql = `
      do $$
      begin
        execute 'select 1; truncate table public.audit_events';
      end
      $$;
    `;
    expect(rules(findDestructiveStatements(sql))).toContain('DYNAMIC TRUNCATE');
  });
});

describe('migration scanner: private-schema grants', () => {
  it('allows grants on private objects to service_role', () => {
    const sql = `
      do $$
      begin
        execute 'grant select, insert, update, delete on private.guest_tokens to service_role';
      end
      $$;
    `;
    expect(findPrivateGrantViolations(sql)).toEqual([]);
  });

  it('allows static service_role grants and default privileges in private', () => {
    const sql = `
      grant select on private.guest_tokens to service_role;
      alter default privileges in schema private grant all on tables to service_role;
      grant usage on schema private to service_role;
    `;
    expect(findPrivateGrantViolations(sql)).toEqual([]);
  });

  it('does not flag grants on public objects to authenticated', () => {
    const sql = 'grant select on public.audit_events to authenticated;';
    expect(findPrivateGrantViolations(sql)).toEqual([]);
  });

  it('flags a static private grant to authenticated', () => {
    const sql = 'grant select on private.guest_tokens to authenticated;';
    expect(rules(findPrivateGrantViolations(sql))).toContain('PRIVATE GRANT');
  });

  it('flags a private schema grant to anon', () => {
    const sql = 'grant usage on schema private to anon;';
    expect(rules(findPrivateGrantViolations(sql))).toContain('PRIVATE GRANT');
  });

  it('flags a private function grant to public', () => {
    const sql = 'grant execute on function private.foo() to public;';
    expect(rules(findPrivateGrantViolations(sql))).toContain('PRIVATE GRANT');
  });

  it('flags a mixed role list that includes an untrusted role', () => {
    const sql =
      'grant select on private.idempotency_keys to service_role, authenticated;';
    expect(rules(findPrivateGrantViolations(sql))).toContain('PRIVATE GRANT');
  });

  it('flags a dynamic private grant to an untrusted role', () => {
    const sql = `
      do $$
      begin
        execute 'grant select on private.idempotency_keys to authenticated';
      end
      $$;
    `;
    expect(rules(findPrivateGrantViolations(sql))).toContain('PRIVATE GRANT');
  });

  it('handles quoted identifiers and role names', () => {
    const sql = 'grant select on "private"."guest_tokens" to "authenticated";';
    expect(rules(findPrivateGrantViolations(sql))).toContain('PRIVATE GRANT');
  });
});

describe('migration scanner: retained security checks', () => {
  it('flags DISABLE ROW LEVEL SECURITY', () => {
    const sql = 'alter table public.audit_events disable row level security;';
    expect(rules(findSecurityIssues(sql))).toContain('DISABLE RLS');
  });

  it('flags SECURITY DEFINER without an explicit search_path', () => {
    const sql = `
      create or replace function private.unsafe()
      returns void
      language plpgsql
      security definer
      as $$ begin null; end $$;
    `;
    expect(rules(findSecurityIssues(sql))).toContain('SECURITY DEFINER');
  });

  it('allows SECURITY DEFINER with an explicit search_path', () => {
    const sql = `
      create or replace function private.safe()
      returns void
      language plpgsql
      security definer
      set search_path = ''
      as $$ begin null; end $$;
    `;
    expect(rules(findSecurityIssues(sql))).not.toContain('SECURITY DEFINER');
  });

  it('reports both destructive and security findings together', () => {
    const sql = `
      truncate table public.audit_events;
      grant select on private.guest_tokens to authenticated;
    `;
    const analysis = analyzeSql(sql);
    expect(rules(analysis.destructive)).toContain('TRUNCATE');
    expect(rules(analysis.security)).toContain('PRIVATE GRANT');
  });
});

describe('migration guard: M2.1 legacy backfill locking', () => {
  it('takes the branch-assignment SHARE lock before the legacy backfill', () => {
    const sql = readFileSync(
      path.resolve(
        process.cwd(),
        'supabase/migrations/20261108120000_m2_branch_scoped_staff_roles.sql',
      ),
      'utf8',
    );

    expect(sql).toMatch(
      /lock table\s+public\.staff_branch_assignments\s+in\s+share\s+mode\s*;\s*(?:--[^\n]*\n\s*)*select\s+private\.backfill_legacy_branch_role_assignments\s*\(\s*\)\s*;/i,
    );
  });

  it('keeps the function-level lock for later manual backfill calls', () => {
    const sql = readFileSync(
      path.resolve(
        process.cwd(),
        'supabase/migrations/20261109130000_m2_staff_rpc_concurrency_and_errors.sql',
      ),
      'utf8',
    );

    expect(sql).toMatch(
      /lock table\s+public\.staff_branch_assignments\s+in\s+share\s+mode\s*;/i,
    );
  });
});
