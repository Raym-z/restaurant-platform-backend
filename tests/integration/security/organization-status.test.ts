import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  authenticateAs,
  createOrgFixture,
  createTable,
  expectPgError,
  setOrganizationStatus,
} from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

const tokenHash = (): string => randomBytes(32).toString("hex");

describe("organization operational status", () => {
  it("blocks staff mutations for suspended and pending-deletion organizations", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    await authenticateAs(owner, fixture.ownerAuthUserId);

    await setOrganizationStatus(admin, fixture.organizationId, "suspended");

    const historicalRead = await owner.query<{ count: string }>(
      "select count(*)::text as count from public.organizations",
    );
    expect(Number(historicalRead.rows[0]!.count)).toBeGreaterThan(0);

    await expectPgError(
      owner.query("select public.update_organization($1, $2) as result", [
        fixture.organizationId,
        "Suspended update",
      ]),
      "ORGANIZATION_NOT_OPERATIONAL",
    );

    await setOrganizationStatus(
      admin,
      fixture.organizationId,
      "pending_deletion",
    );

    await expectPgError(
      owner.query(
        "select public.create_branch($1, $2, $3, null, null, null) as result",
        [fixture.organizationId, "Deletion branch", "Asia/Jakarta"],
      ),
      "ORGANIZATION_NOT_OPERATIONAL",
    );
  });

  it("rejects existing guest tokens for suspended organizations but allows pending deletion reads", async () => {
    const admin = await createClient();
    const guest = await createClient();
    clients.push(admin, guest);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const hash = tokenHash();

    await authenticateAs(guest, randomUUID(), "service_role");
    const resolved = await guest.query<{ result: Record<string, unknown> }>(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, hash],
    );
    expect(resolved.rows[0]!.result.sessionId).toBeDefined();

    await setOrganizationStatus(admin, fixture.organizationId, "suspended");
    await expectPgError(
      guest.query("select public.validate_guest_token($1) as result", [hash]),
      "GUEST_TOKEN_INVALID",
    );

    await setOrganizationStatus(
      admin,
      fixture.organizationId,
      "pending_deletion",
    );
    const pendingRead = await guest.query<{ result: Record<string, unknown> }>(
      "select public.validate_guest_token($1) as result",
      [hash],
    );
    expect(pendingRead.rows[0]!.result.sessionId).toBeDefined();
  });
});
