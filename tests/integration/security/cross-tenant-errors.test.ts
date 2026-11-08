import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  authenticateAs,
  createCustomer,
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

describe("cross-tenant error consistency", () => {
  it("returns the same not-found code for missing and other-tenant tables", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const first = await createOrgFixture(admin, { branchCount: 1 });
    const second = await createOrgFixture(admin, { branchCount: 1 });
    const secondTable = await createTable(admin, {
      organizationId: second.organizationId,
      branchId: second.branchIds[0]!,
    });

    await authenticateAs(owner, first.ownerAuthUserId);

    await expectPgError(
      owner.query("select public.deactivate_table($1, $2) as result", [
        randomUUID(),
        "missing",
      ]),
      "TABLE_NOT_FOUND",
    );

    await expectPgError(
      owner.query("select public.deactivate_table($1, $2) as result", [
        secondTable.tableId,
        "other tenant",
      ]),
      "TABLE_NOT_FOUND",
    );

    await expectPgError(
      owner.query("select public.update_organization($1, $2) as result", [
        second.organizationId,
        "Other tenant",
      ]),
      "ORGANIZATION_NOT_FOUND",
    );

    await expectPgError(
      owner.query(
        "select public.update_branch($1, $2, $3, null, null) as result",
        [second.branchIds[0]!, "Other tenant", "Asia/Jakarta"],
      ),
      "BRANCH_NOT_FOUND",
    );

    await expectPgError(
      owner.query("select public.update_table($1, $2, $3) as result", [
        secondTable.tableId,
        "Other tenant",
        4,
      ]),
      "TABLE_NOT_FOUND",
    );

    await expectPgError(
      owner.query("select public.regenerate_table_qr($1) as result", [
        secondTable.tableId,
      ]),
      "TABLE_NOT_FOUND",
    );
  });

  it("normalizes menu and staff cross-tenant errors", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const first = await createOrgFixture(admin, { branchCount: 1 });
    const second = await createOrgFixture(admin, { branchCount: 1 });
    const categoryId = randomUUID();
    const menuItemId = randomUUID();

    await admin.query(
      `insert into public.menu_categories (id, organization_id, name)
       values ($1, $2, 'Other category')`,
      [categoryId, second.organizationId],
    );
    await admin.query(
      `insert into public.menu_items
         (id, organization_id, category_id, name, base_price_minor, currency_code)
       values ($1, $2, $3, 'Other item', 1000, 'IDR')`,
      [menuItemId, second.organizationId, categoryId],
    );

    await authenticateAs(owner, first.ownerAuthUserId);

    await expectPgError(
      owner.query(
        "select public.update_menu_item($1, $2, $3, null, 0) as result",
        [randomUUID(), "Missing item", 1000],
      ),
      "MENU_ITEM_NOT_FOUND",
    );
    await expectPgError(
      owner.query(
        "select public.update_menu_item($1, $2, $3, null, 0) as result",
        [menuItemId, "Other item", 1000],
      ),
      "MENU_ITEM_NOT_FOUND",
    );

    await expectPgError(
      owner.query(
        "select public.grant_staff_role($1, $2, $3::public.role_scope, null) as result",
        [randomUUID(), "manager", "branch"],
      ),
      "RESOURCE_CONFLICT",
    );
    await expectPgError(
      owner.query(
        "select public.grant_staff_role($1, $2, $3::public.role_scope, null) as result",
        [second.ownerStaffId, "manager", "branch"],
      ),
      "RESOURCE_CONFLICT",
    );

    await expectPgError(
      owner.query(
        "select public.add_walk_in($1, $2, $3, $4) as result",
        [randomUUID(), 2, "Missing branch", "+628123456789"],
      ),
      "BRANCH_NOT_FOUND",
    );
    await expectPgError(
      owner.query(
        "select public.add_walk_in($1, $2, $3, $4) as result",
        [second.branchIds[0]!, 2, "Other tenant", "+628123456789"],
      ),
      "BRANCH_NOT_FOUND",
    );
  });

  it("does not reveal another tenant's guest token through revocation errors", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const guest = await createClient();
    clients.push(admin, owner, guest);

    const first = await createOrgFixture(admin, { branchCount: 1 });
    const second = await createOrgFixture(admin, { branchCount: 1 });
    const secondTable = await createTable(admin, {
      organizationId: second.organizationId,
      branchId: second.branchIds[0]!,
    });
    const hash = tokenHash();

    await authenticateAs(guest, randomUUID(), "service_role");
    const resolved = await guest.query<{ result: Record<string, unknown> }>(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [secondTable.qrPublicId, hash],
    );
    const sessionId = String(resolved.rows[0]!.result.sessionId);

    const token = await admin.query<{ id: string }>(
      "select id from private.guest_tokens where dining_session_id = $1 limit 1",
      [sessionId],
    );

    await authenticateAs(owner, first.ownerAuthUserId);
    await expectPgError(
      owner.query("select public.revoke_guest_token($1, $2) as result", [
        token.rows[0]!.id,
        "other tenant",
      ]),
      "GUEST_TOKEN_INVALID",
    );
  });

  it("does not reveal another tenant's waitlist entry", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const first = await createOrgFixture(admin, { branchCount: 1 });
    const second = await createOrgFixture(admin, { branchCount: 1 });
    const customer = await createCustomer(admin);
    const entryId = randomUUID();

    await admin.query(
      `insert into public.waitlist_entries
         (id, organization_id, branch_id, customer_id, contact_name, party_size, status)
       values ($1, $2, $3, $4, 'Other customer', 2, 'waiting')`,
      [
        entryId,
        second.organizationId,
        second.branchIds[0]!,
        customer.customerId,
      ],
    );

    await authenticateAs(owner, first.ownerAuthUserId);
    await expectPgError(
      owner.query("select public.cancel_waitlist_entry($1, $2) as result", [
        entryId,
        "other tenant",
      ]),
      "WAITLIST_ENTRY_NOT_FOUND",
    );
  });
});
