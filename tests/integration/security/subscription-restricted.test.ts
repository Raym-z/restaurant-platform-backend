import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  authenticateAs,
  createOrgFixture,
  createTable,
  expectPgError,
} from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

const tokenHash = (): string => randomBytes(32).toString("hex");

describe("subscription restricted behavior", () => {
  it("uses SUBSCRIPTION_RESTRICTED consistently while preserving existing guest reads", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const guest = await createClient();
    clients.push(admin, owner, guest);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const existingHash = tokenHash();

    await authenticateAs(guest, randomUUID(), "service_role");
    await guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, existingHash],
    );

    await admin.query(
      `update public.subscriptions
          set state = 'restricted'
        where organization_id = $1`,
      [fixture.organizationId],
    );

    await authenticateAs(owner, fixture.ownerAuthUserId);
    await expectPgError(
      owner.query(
        "select public.create_branch($1, $2, $3, null, null, null) as result",
        [fixture.organizationId, "Restricted branch", "Asia/Jakarta"],
      ),
      "SUBSCRIPTION_RESTRICTED",
    );
    await expectPgError(
      owner.query("select public.create_table($1, $2, $3) as result", [
        branchId,
        "Restricted table",
        4,
      ]),
      "SUBSCRIPTION_RESTRICTED",
    );

    await authenticateAs(guest, randomUUID(), "service_role");
    await expectPgError(
      guest.query(
        "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
        [table.qrPublicId, tokenHash()],
      ),
      "SUBSCRIPTION_RESTRICTED",
    );

    const existing = await guest.query<{ result: Record<string, unknown> }>(
      "select public.validate_guest_token($1) as result",
      [existingHash],
    );
    expect(existing.rows[0]!.result.sessionId).toBeDefined();
  });
});
