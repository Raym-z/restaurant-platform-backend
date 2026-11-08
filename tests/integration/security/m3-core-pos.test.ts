import { randomBytes, randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  addStaff,
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

const openSession = async (
  client: pg.Client,
  tableId: string,
  idempotencyKey?: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.open_dining_session($1, $2) as result",
    [tableId, idempotencyKey ?? null],
  );
  return result.rows[0]!.result;
};

const createOrder = async (
  client: pg.Client,
  sessionId: string,
  items: unknown,
  idempotencyKey?: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.create_order($1, $2::jsonb, null, $3) as result",
    [sessionId, JSON.stringify(items), idempotencyKey ?? null],
  );
  return result.rows[0]!.result;
};

const transition = async (
  client: pg.Client,
  orderId: string,
  status: string,
  reason?: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.transition_order_status($1, $2::public.order_status, $3) as result",
    [orderId, status, reason ?? null],
  );
  return result.rows[0]!.result;
};

const cancelOrder = async (
  client: pg.Client,
  orderId: string,
  reason: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.cancel_order($1, $2) as result",
    [orderId, reason],
  );
  return result.rows[0]!.result;
};

const createMenuItem = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    name: string;
    basePriceMinor: number;
    branchAvailable?: boolean;
    priceOverrideMinor?: number | null;
  },
): Promise<{ categoryId: string; itemId: string }> => {
  const category = await admin.query<{ id: string }>(
    `insert into public.menu_categories (organization_id, name)
     values ($1, $2)
     returning id`,
    [options.organizationId, `Category ${randomUUID().slice(0, 8)}`],
  );

  const item = await admin.query<{ id: string }>(
    `insert into public.menu_items
       (organization_id, category_id, name, base_price_minor, currency_code)
     values ($1, $2, $3, $4, 'IDR')
     returning id`,
    [
      options.organizationId,
      category.rows[0]!.id,
      options.name,
      options.basePriceMinor,
    ],
  );

  await admin.query(
    `insert into public.branch_menu_items
       (organization_id, branch_id, menu_item_id, is_available, price_override_minor)
     values ($1, $2, $3, $4, $5)`,
    [
      options.organizationId,
      options.branchId,
      item.rows[0]!.id,
      options.branchAvailable ?? true,
      options.priceOverrideMinor ?? null,
    ],
  );

  return { categoryId: category.rows[0]!.id, itemId: item.rows[0]!.id };
};

const createModifier = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    menuItemId: string;
    name: string;
    priceDeltaMinor: number;
    minSelections?: number;
    maxSelections?: number;
  },
): Promise<{ groupId: string; optionId: string }> => {
  const group = await admin.query<{ id: string }>(
    `insert into public.modifier_groups
       (organization_id, name, min_selections, max_selections)
     values ($1, $2, $3, $4)
     returning id`,
    [
      options.organizationId,
      options.name,
      options.minSelections ?? 0,
      options.maxSelections ?? 1,
    ],
  );

  const option = await admin.query<{ id: string }>(
    `insert into public.modifier_options
       (organization_id, modifier_group_id, name, price_delta_minor)
     values ($1, $2, $3, $4)
     returning id`,
    [
      options.organizationId,
      group.rows[0]!.id,
      `${options.name} option`,
      options.priceDeltaMinor,
    ],
  );

  await admin.query(
    `insert into public.menu_item_modifier_groups
       (organization_id, menu_item_id, modifier_group_id)
     values ($1, $2, $3)`,
    [options.organizationId, options.menuItemId, group.rows[0]!.id],
  );

  return { groupId: group.rows[0]!.id, optionId: option.rows[0]!.id };
};

describe("M3 table availability and dining sessions", () => {
  it("lists accessible branch tables and reports current availability", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const branchId = fixture.branchIds[0]!;
    const otherBranchId = fixture.branchIds[1]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const otherManager = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [otherBranchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
      label: "T1",
    });

    await authenticateAs(manager, managerFixture.authUserId);

    const list = await manager.query<{ result: Record<string, unknown> }>(
      "select public.list_branch_tables($1, false) as result",
      [branchId],
    );
    const tables = list.rows[0]!.result.tables as Array<Record<string, unknown>>;
    expect(tables).toHaveLength(1);
    expect(tables[0]!.tableId).toBe(table.tableId);
    expect(tables[0]!.availability).toBe("available");

    const opened = await openSession(manager, table.tableId);
    expect(opened.status).toBe("active");
    expect(opened.openedByStaffId).toBe(managerFixture.staffId);

    const availability = await manager.query<{
      result: Record<string, unknown>;
    }>("select public.get_table_availability($1) as result", [table.tableId]);
    expect(availability.rows[0]!.result.availability).toBe("occupied");
    expect(availability.rows[0]!.result.activeSessionId).toBe(
      opened.sessionId,
    );

    await authenticateAs(manager, otherManager.authUserId);
    await expectPgError(
      manager.query("select public.list_branch_tables($1, false) as result", [
        branchId,
      ]),
      "BRANCH_ACCESS_DENIED",
    );
    await expectPgError(
      manager.query("select public.get_table($1) as result", [table.tableId]),
      "BRANCH_ACCESS_DENIED",
    );
  });

  it("rejects duplicate and inactive-table session opens", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
      label: "T1",
    });
    const inactiveTable = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
      label: "T2",
    });

    await admin.query(
      `update public.restaurant_tables
          set status = 'inactive', deactivated_at = now()
        where id = $1`,
      [inactiveTable.tableId],
    );

    await authenticateAs(manager, managerFixture.authUserId);
    await openSession(manager, table.tableId);

    await expectPgError(
      openSession(manager, table.tableId),
      "RESOURCE_CONFLICT",
    );
    await expectPgError(
      openSession(manager, inactiveTable.tableId),
      "RESOURCE_CONFLICT",
    );

    const sessions = await admin.query<{ count: string }>(
      `select count(*)::text as count
         from public.dining_sessions
        where table_id = $1
          and status = 'active'`,
      [table.tableId],
    );
    expect(Number(sessions.rows[0]!.count)).toBe(1);
  });

  it("retains historical sessions after table deactivation", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const sessionId = String(session.sessionId);
    await manager.query("select public.close_dining_session($1, $2) as result", [
      sessionId,
      "empty",
    ]);

    await manager.query("select public.deactivate_table($1, $2) as result", [
      table.tableId,
      "retired",
    ]);

    const historical = await manager.query<{ result: Record<string, unknown> }>(
      "select public.get_dining_session($1) as result",
      [sessionId],
    );
    expect(historical.rows[0]!.result.status).toBe("closed");
    expect(historical.rows[0]!.result.sessionId).toBe(sessionId);

    const tableDetail = await manager.query<{ result: Record<string, unknown> }>(
      "select public.get_table($1) as result",
      [table.tableId],
    );
    expect(tableDetail.rows[0]!.result.status).toBe("inactive");
    expect(tableDetail.rows[0]!.result.availability).toBe("inactive");

    const activeOnly = await manager.query<{
      result: Record<string, unknown>;
    }>("select public.list_branch_tables($1, false) as result", [branchId]);
    expect((activeOnly.rows[0]!.result.tables as unknown[]).length).toBe(0);

    const includingInactive = await manager.query<{
      result: Record<string, unknown>;
    }>("select public.list_branch_tables($1, true) as result", [branchId]);
    expect(
      (includingInactive.rows[0]!.result.tables as unknown[]).length,
    ).toBe(1);
  });

  it("serializes concurrent opens to one active session", async () => {
    const admin = await createClient();
    const first = await createClient();
    const second = await createClient();
    clients.push(admin, first, second);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const owner = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    await authenticateAs(first, owner.authUserId);
    await authenticateAs(second, owner.authUserId);

    const results = await Promise.allSettled([
      first.query("select public.open_dining_session($1, null) as result", [
        table.tableId,
      ]),
      second.query("select public.open_dining_session($1, null) as result", [
        table.tableId,
      ]),
    ]);

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(
      1,
    );

    const sessions = await admin.query<{ count: string }>(
      `select count(*)::text as count
         from public.dining_sessions
        where table_id = $1
          and status = 'active'`,
      [table.tableId],
    );
    expect(Number(sessions.rows[0]!.count)).toBe(1);
  });
});

describe("M3 order creation and pricing", () => {
  it("uses authoritative branch price and modifier snapshots", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const menuItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Nasi Goreng",
      basePriceMinor: 10000,
      priceOverrideMinor: 12000,
    });
    const modifier = await createModifier(admin, {
      organizationId: fixture.organizationId,
      menuItemId: menuItem.itemId,
      name: "Extra egg",
      priceDeltaMinor: 500,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);

    const order = await createOrder(manager, String(session.sessionId), [
      {
        menuItemId: menuItem.itemId,
        quantity: 2,
        modifierOptionIds: [modifier.optionId],
      },
    ]);

    expect(order.subtotalMinor).toBe(25000);
    expect(String(order.orderReference)).toMatch(/^ORD-\d{8}$/);
    expect(order.source).toBe("staff");
    expect(order.status).toBe("pending");
    expect(order.submittedByStaffId).toBe(managerFixture.staffId);

    const items = order.items as Array<Record<string, unknown>>;
    expect(items).toHaveLength(1);
    expect(items[0]!.baseUnitPriceMinor).toBe(12000);
    expect(items[0]!.modifierUnitDeltaMinor).toBe(500);
    expect(items[0]!.lineTotalMinor).toBe(25000);
    expect((items[0]!.modifiers as unknown[]).length).toBe(1);
  });

  it("rejects unavailable items, invalid quantities, and client price fields", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const availableItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Available",
      basePriceMinor: 10000,
    });
    const unavailableItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Unavailable",
      basePriceMinor: 10000,
      branchAvailable: false,
    });
    const requiredModifierItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Required modifier",
      basePriceMinor: 10000,
    });
    await createModifier(admin, {
      organizationId: fixture.organizationId,
      menuItemId: requiredModifierItem.itemId,
      name: "Required choice",
      priceDeltaMinor: 0,
      minSelections: 1,
      maxSelections: 1,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const sessionId = String(session.sessionId);

    await expectPgError(
      createOrder(manager, sessionId, [
        { menuItemId: unavailableItem.itemId, quantity: 1 },
      ]),
      "MENU_ITEM_UNAVAILABLE",
    );

    await expectPgError(
      createOrder(manager, sessionId, [
        { menuItemId: availableItem.itemId, quantity: 0 },
      ]),
      "ORDER_ITEM_QUANTITY_INVALID",
    );

    await expectPgError(
      createOrder(manager, sessionId, [
        { menuItemId: availableItem.itemId, quantity: 1, priceMinor: 1 },
      ]),
      "VALIDATION_ERROR",
    );

    await expectPgError(
      createOrder(manager, sessionId, [
        { menuItemId: requiredModifierItem.itemId, quantity: 1 },
      ]),
      "INVALID_MODIFIER_SELECTION",
    );

    await manager.query("select public.close_dining_session($1, $2) as result", [
      sessionId,
      "empty",
    ]);

    await expectPgError(
      createOrder(manager, sessionId, [
        { menuItemId: availableItem.itemId, quantity: 1 },
      ]),
      "SESSION_NOT_ACTIVE",
    );
  });

  it("lists session and branch orders with status filters and pagination", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const menuItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Listed item",
      basePriceMinor: 10000,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const sessionId = String(session.sessionId);

    await createOrder(manager, sessionId, [
      { menuItemId: menuItem.itemId, quantity: 1 },
    ]);
    await createOrder(manager, sessionId, [
      { menuItemId: menuItem.itemId, quantity: 2 },
    ]);

    const firstPage = await manager.query<{ result: Record<string, unknown> }>(
      "select public.list_orders_by_session($1, null::public.order_status, 1, 0) as result",
      [sessionId],
    );
    expect(
      (firstPage.rows[0]!.result.orders as unknown[]).length,
    ).toBe(1);
    expect(firstPage.rows[0]!.result.hasMore).toBe(true);
    expect(firstPage.rows[0]!.result.nextOffset).toBe(1);

    const filtered = await manager.query<{ result: Record<string, unknown> }>(
      "select public.list_orders_by_session($1, 'pending'::public.order_status, 10, 0) as result",
      [sessionId],
    );
    expect((filtered.rows[0]!.result.orders as unknown[]).length).toBe(2);

    const branchOrders = await manager.query<{
      result: Record<string, unknown>;
    }>(
      "select public.list_branch_orders($1, 'pending'::public.order_status, null::timestamptz, null::timestamptz, 10, 0) as result",
      [branchId],
    );
    expect(
      (branchOrders.rows[0]!.result.orders as unknown[]).length,
    ).toBe(2);
  });

  it("replays idempotent order creation and rejects key reuse", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const menuItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Idempotent item",
      basePriceMinor: 10000,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const key = "idem-key-order-1234567890";
    const items = [{ menuItemId: menuItem.itemId, quantity: 1 }];

    const first = await createOrder(manager, String(session.sessionId), items, key);
    const replay = await createOrder(
      manager,
      String(session.sessionId),
      items,
      key,
    );

    expect(replay.orderId).toBe(first.orderId);

    const count = await admin.query<{ count: string }>(
      "select count(*)::text as count from public.orders where dining_session_id = $1",
      [session.sessionId],
    );
    expect(Number(count.rows[0]!.count)).toBe(1);

    await expectPgError(
      createOrder(
        manager,
        String(session.sessionId),
        [{ menuItemId: menuItem.itemId, quantity: 2 }],
        key,
      ),
      "IDEMPOTENCY_CONFLICT",
    );
  });
});

describe("M3 order item modification and lifecycle", () => {
  it("modifies items only before preparation and recalculates subtotal", async () => {
    const admin = await createClient();
    const manager = await createClient();
    clients.push(admin, manager);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const firstItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Item one",
      basePriceMinor: 10000,
    });
    const secondItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Item two",
      basePriceMinor: 20000,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const order = await createOrder(manager, String(session.sessionId), [
      { menuItemId: firstItem.itemId, quantity: 1 },
    ]);
    const orderId = String(order.orderId);
    const firstOrderItemId = String(
      (order.items as Array<Record<string, unknown>>)[0]!.orderItemId,
    );

    const afterAdd = await manager.query<{ result: Record<string, unknown> }>(
      "select public.add_order_item($1, $2, $3, $4::uuid[], null) as result",
      [orderId, secondItem.itemId, 2, []],
    );
    expect(afterAdd.rows[0]!.result.subtotalMinor).toBe(50000);

    const afterQuantity = await manager.query<{
      result: Record<string, unknown>;
    }>("select public.update_order_item_quantity($1, $2) as result", [
      firstOrderItemId,
      2,
    ]);
    expect(afterQuantity.rows[0]!.result.subtotalMinor).toBe(60000);

    const secondOrderItemId = String(
      (afterAdd.rows[0]!.result.items as Array<Record<string, unknown>>).find(
        (item) => item.menuItemId === secondItem.itemId,
      )!.orderItemId,
    );

    const afterRemove = await manager.query<{ result: Record<string, unknown> }>(
      "select public.remove_order_item($1, $2) as result",
      [secondOrderItemId, "duplicate"],
    );
    expect(afterRemove.rows[0]!.result.subtotalMinor).toBe(20000);

    await transition(manager, orderId, "accepted");
    const afterPreparing = await transition(manager, orderId, "preparing");
    expect(afterPreparing.status).toBe("preparing");

    await expectPgError(
      manager.query(
        "select public.add_order_item($1, $2, $3, $4::uuid[], null) as result",
        [orderId, secondItem.itemId, 1, []],
      ),
      "ORDER_MODIFICATION_NOT_ALLOWED",
    );

    await expectPgError(
      manager.query("select public.update_order_item_quantity($1, $2) as result", [
        firstOrderItemId,
        1,
      ]),
      "ORDER_MODIFICATION_NOT_ALLOWED",
    );
  });

  it("enforces transitions, cancellation actor, reason, and audit records", async () => {
    const admin = await createClient();
    const manager = await createClient();
    const kitchen = await createClient();
    const cashier = await createClient();
    clients.push(admin, manager, kitchen, cashier);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const kitchenFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "kitchen_staff",
      scope: "branch",
      branchIds: [branchId],
    });
    const cashierFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "cashier",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const kitchenTable = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
      label: "T-kitchen",
    });
    const menuItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Lifecycle item",
      basePriceMinor: 10000,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const order = await createOrder(manager, String(session.sessionId), [
      { menuItemId: menuItem.itemId, quantity: 1 },
    ]);
    const orderId = String(order.orderId);

    await expectPgError(
      transition(manager, orderId, "preparing"),
      "ORDER_INVALID_STATUS",
    );

    await transition(manager, orderId, "accepted");
    await authenticateAs(kitchen, kitchenFixture.authUserId);
    await expectPgError(
      openSession(kitchen, kitchenTable.tableId),
      "PERMISSION_DENIED",
    );
    await transition(kitchen, orderId, "preparing");
    await transition(kitchen, orderId, "ready");
    await authenticateAs(cashier, cashierFixture.authUserId);
    await transition(cashier, orderId, "served");
    const completed = await transition(cashier, orderId, "completed");
    expect(completed.status).toBe("completed");
    expect(completed.completedAt).not.toBeNull();
    expect(
      (completed.items as Array<Record<string, unknown>>).every(
        (item) => item.status === "served",
      ),
    ).toBe(true);

    await authenticateAs(manager, managerFixture.authUserId);
    await expectPgError(
      transition(manager, orderId, "preparing"),
      "ORDER_INVALID_STATUS",
    );

    const secondOrder = await createOrder(manager, String(session.sessionId), [
      { menuItemId: menuItem.itemId, quantity: 1 },
    ]);
    const secondOrderId = String(secondOrder.orderId);

    // Defense in depth: a privileged direct update cannot skip the matrix.
    await expect(
      admin.query("update public.orders set status = 'preparing' where id = $1", [
        secondOrderId,
      ]),
    ).rejects.toThrow(/ORDER_INVALID_STATUS/);

    await expectPgError(
      manager.query("select public.cancel_order($1, $2) as result", [
        secondOrderId,
        "   ",
      ]),
      "VALIDATION_ERROR",
    );

    await authenticateAs(kitchen, kitchenFixture.authUserId);
    await expectPgError(cancelOrder(kitchen, secondOrderId, "not allowed"), "PERMISSION_DENIED");

    await authenticateAs(manager, managerFixture.authUserId);
    const cancelled = await cancelOrder(manager, secondOrderId, "Customer left");
    expect(cancelled.status).toBe("cancelled");
    expect(cancelled.cancelledByStaffId).toBe(managerFixture.staffId);
    expect(cancelled.cancelledAt).not.toBeNull();
    expect(cancelled.cancellationReason).toBe("Customer left");

    await expectPgError(
      transition(manager, secondOrderId, "accepted"),
      "ORDER_INVALID_STATUS",
    );

    const audit = await admin.query<{ action: string }>(
      "select action from public.audit_events where target_id = $1 order by created_at",
      [secondOrderId],
    );
    expect(audit.rows.map((row) => row.action)).toContain("order.created");
    expect(audit.rows.map((row) => row.action)).toContain("order.cancelled");
  });

  it("blocks closing while orders remain and revokes guest tokens on close", async () => {
    const admin = await createClient();
    const manager = await createClient();
    const guest = await createClient();
    clients.push(admin, manager, guest);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });
    const menuItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: "Close item",
      basePriceMinor: 10000,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);
    const sessionId = String(session.sessionId);
    const order = await createOrder(manager, sessionId, [
      { menuItemId: menuItem.itemId, quantity: 1 },
    ]);

    await authenticateAs(guest, randomUUID(), "service_role");
    await guest.query(
      "select public.resolve_or_create_dining_session($1, $2, null, now() + interval '1 hour') as result",
      [table.qrPublicId, tokenHash()],
    );

    await authenticateAs(manager, managerFixture.authUserId);
    await expectPgError(
      manager.query("select public.close_dining_session($1, $2) as result", [
        sessionId,
        "closing",
      ]),
      "SESSION_BALANCE_OUTSTANDING",
    );

    await cancelOrder(manager, String(order.orderId), "Test cleanup");
    const closed = await manager.query<{ result: Record<string, unknown> }>(
      "select public.close_dining_session($1, $2) as result",
      [sessionId, "closing"],
    );
    expect(closed.rows[0]!.result.status).toBe("closed");
    expect(closed.rows[0]!.result.closedByStaffId).toBe(managerFixture.staffId);
    expect(closed.rows[0]!.result.closedAt).not.toBeNull();

    await expectPgError(
      manager.query("select public.close_dining_session($1, $2) as result", [
        sessionId,
        "again",
      ]),
      "SESSION_ALREADY_CLOSED",
    );

    const tokens = await admin.query<{ revoked_at: string | null }>(
      "select revoked_at from private.guest_tokens where dining_session_id = $1",
      [sessionId],
    );
    expect(tokens.rows.length).toBeGreaterThan(0);
    expect(tokens.rows.every((row) => row.revoked_at !== null)).toBe(true);
  });
});

describe("M3 authorization boundaries", () => {
  it("denies inactive staff, cross-organization access, and direct writes", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const manager = await createClient();
    const otherOwner = await createClient();
    clients.push(admin, owner, manager, otherOwner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const otherFixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const managerFixture = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchId],
    });
    const table = await createTable(admin, {
      organizationId: fixture.organizationId,
      branchId,
    });

    await authenticateAs(manager, managerFixture.authUserId);
    const session = await openSession(manager, table.tableId);

    await authenticateAs(otherOwner, otherFixture.ownerAuthUserId);
    await expectPgError(
      otherOwner.query("select public.get_table($1) as result", [table.tableId]),
      "TABLE_NOT_FOUND",
    );
    await expectPgError(
      otherOwner.query("select public.create_order($1, $2::jsonb, null, null) as result", [
        session.sessionId,
        JSON.stringify([]),
      ]),
      "DINING_SESSION_NOT_FOUND",
    );

    await admin.query(
      "update public.staff_profiles set status = 'suspended' where id = $1",
      [managerFixture.staffId],
    );
    await authenticateAs(manager, managerFixture.authUserId);
    await expectPgError(
      manager.query("select public.list_branch_tables($1, false) as result", [
        branchId,
      ]),
      "STAFF_NOT_ACTIVE",
    );

    await admin.query(
      `update public.branches
          set status = 'inactive', deactivated_at = now()
        where id = $1`,
      [branchId],
    );

    await authenticateAs(owner, fixture.ownerAuthUserId);
    await expectPgError(
      owner.query("select public.list_branch_tables($1, false) as result", [
        branchId,
      ]),
      "BRANCH_ACCESS_DENIED",
    );

    const directInsert = owner.query(
      `insert into public.orders
         (organization_id, branch_id, dining_session_id, source, status, currency_code, subtotal_minor)
       values ($1, $2, $3, 'staff', 'pending', 'IDR', 0)`,
      [fixture.organizationId, branchId, session.sessionId],
    );
    await expect(directInsert).rejects.toThrow(/permission denied/i);
  });
});
