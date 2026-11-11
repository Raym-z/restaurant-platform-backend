import { randomUUID } from "node:crypto";

import type pg from "pg";
import { afterAll, afterEach, describe, expect, it } from "vitest";

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

afterEach(async () => {
  const active = clients.splice(0);
  await Promise.all(active.map((client) => client.end().catch(() => undefined)));
});

const track = <T extends pg.Client[]>(...created: T): T => {
  clients.push(...created);
  return created;
};

const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
let nameSeq = 0;
const uniqueName = (label: string): string =>
  `${label} ${suffix} ${++nameSeq}`;

type Fixture = {
  organizationId: string;
  branchIds: string[];
  ownerAuthUserId: string;
  ownerStaffId: string;
};

type Board = {
  branchId: string;
  stationId: string | null;
  statuses: string[];
  from: string | null;
  to: string | null;
  tickets: Array<Record<string, unknown>>;
  pageSize: number;
  hasMore: boolean;
  nextOffset: number | null;
};

type OrderItemInput = {
  menuItemId: string;
  quantity?: number;
  modifierOptionIds?: string[];
  notes?: string;
};

const createOwnerClient = async (fixture: Fixture): Promise<pg.Client> => {
  const owner = await createClient();
  track(owner);
  await authenticateAs(owner, fixture.ownerAuthUserId);
  return owner;
};

const createBranchStaff = async (
  admin: pg.Client,
  fixture: Fixture,
  role: "manager" | "cashier" | "kitchen_staff",
  branchIds: string[],
): Promise<{ client: pg.Client; staffId: string; authUserId: string }> => {
  const staff = await addStaff(admin, {
    organizationId: fixture.organizationId,
    role,
    scope: "branch",
    branchIds,
  });
  const client = await createClient();
  track(client);
  await authenticateAs(client, staff.authUserId);
  return { client, ...staff };
};

const createMenuItem = async (
  admin: pg.Client,
  options: { organizationId: string; name: string },
): Promise<{ categoryId: string; itemId: string }> => {
  const category = await admin.query<{ id: string }>(
    `insert into public.menu_categories (organization_id, name)
     values ($1, $2)
     returning id`,
    [options.organizationId, `${options.name} category`],
  );
  const item = await admin.query<{ id: string }>(
    `insert into public.menu_items
       (organization_id, category_id, name, base_price_minor, currency_code)
     values ($1, $2, $3, 10000, 'IDR')
     returning id`,
    [options.organizationId, category.rows[0]!.id, options.name],
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
  },
): Promise<{ groupId: string; optionId: string }> => {
  const group = await admin.query<{ id: string }>(
    `insert into public.modifier_groups
       (organization_id, name, min_selections, max_selections)
     values ($1, $2, 0, 1)
     returning id`,
    [options.organizationId, options.name],
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

const createStation = async (
  owner: pg.Client,
  branchId: string,
  name: string,
): Promise<string> => {
  const result = await owner.query<{ result: Record<string, unknown> }>(
    "select public.create_kitchen_station($1, $2, null) as result",
    [branchId, name],
  );
  return String(result.rows[0]!.result.stationId);
};

const routeItem = async (
  owner: pg.Client,
  stationId: string,
  menuItemId: string,
): Promise<void> => {
  await owner.query(
    "select public.add_kitchen_station_item_route($1, $2)",
    [stationId, menuItemId],
  );
};

const createSessionForBranch = async (
  admin: pg.Client,
  fixture: Fixture,
  branchId: string,
  label: string,
): Promise<string> => {
  const table = await createTable(admin, {
    organizationId: fixture.organizationId,
    branchId,
    label,
  });
  const session = await admin.query<{ id: string }>(
    `insert into public.dining_sessions
       (organization_id, branch_id, table_id, opened_by_staff_id)
     values ($1, $2, $3, $4)
     returning id`,
    [
      fixture.organizationId,
      branchId,
      table.tableId,
      fixture.ownerStaffId,
    ],
  );
  return session.rows[0]!.id;
};

const createOrder = async (
  client: pg.Client,
  sessionId: string,
  items: OrderItemInput[],
  notes?: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.create_order($1, $2::jsonb, $3, null) as result",
    [sessionId, JSON.stringify(items), notes ?? null],
  );
  return result.rows[0]!.result;
};

const transition = async (
  client: pg.Client,
  orderId: string,
  status: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.transition_order_status($1, $2::public.order_status, null) as result",
    [orderId, status],
  );
  return result.rows[0]!.result;
};

const listBoard = async (
  client: pg.Client,
  branchId: string,
  options: {
    stationId?: string | null;
    statuses?: string[] | null;
    limit?: number;
    offset?: number;
    from?: string | null;
    to?: string | null;
  } = {},
): Promise<Board> => {
  const result = await client.query<{ result: Board }>(
    `select public.list_kitchen_tickets(
       $1,
       $2,
       $3::public.kitchen_ticket_status[],
       $4,
       $5,
       $6,
       $7
     ) as result`,
    [
      branchId,
      options.stationId ?? null,
      options.statuses ?? null,
      options.limit ?? 50,
      options.offset ?? 0,
      options.from ?? null,
      options.to ?? null,
    ],
  );
  return result.rows[0]!.result;
};

const getTicket = async (
  client: pg.Client,
  ticketId: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.get_kitchen_ticket($1) as result",
    [ticketId],
  );
  return result.rows[0]!.result;
};

const startItem = async (
  client: pg.Client,
  ticketItemId: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.start_kitchen_ticket_item($1) as result",
    [ticketItemId],
  );
  return result.rows[0]!.result;
};

const readyItem = async (
  client: pg.Client,
  ticketItemId: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.mark_kitchen_ticket_item_ready($1) as result",
    [ticketItemId],
  );
  return result.rows[0]!.result;
};

const completeItem = async (
  client: pg.Client,
  ticketItemId: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.complete_kitchen_ticket_item($1) as result",
    [ticketItemId],
  );
  return result.rows[0]!.result;
};

const collectKeys = (value: unknown, keys: Set<string>): void => {
  if (Array.isArray(value)) {
    for (const entry of value) collectKeys(entry, keys);
    return;
  }
  if (value !== null && typeof value === "object") {
    for (const [key, entry] of Object.entries(value)) {
      keys.add(key);
      collectKeys(entry, keys);
    }
  }
};

describe("M4.3 KDS read APIs", () => {
  it("returns a complete board with station, order, table, modifiers, and no financial fields", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const branchId = fixture.branchIds[0]!;
    const owner = await createOwnerClient(fixture);
    const cashier = await createBranchStaff(admin, fixture, "cashier", [
      branchId,
    ]);
    const kitchen = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchId,
    ]);

    const main = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Board item"),
    });
    const drink = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Board drink"),
    });
    const modifier = await createModifier(admin, {
      organizationId: fixture.organizationId,
      menuItemId: main.itemId,
      name: uniqueName("Spice"),
      priceDeltaMinor: 500,
    });
    const hotLine = await createStation(owner, branchId, uniqueName("Hot line"));
    const bar = await createStation(owner, branchId, uniqueName("Bar"));
    await routeItem(owner, hotLine, main.itemId);
    await routeItem(owner, bar, drink.itemId);

    const tableLabel = uniqueName("T12");
    const sessionId = await createSessionForBranch(
      admin,
      fixture,
      branchId,
      tableLabel,
    );
    const order = await createOrder(
      cashier.client,
      sessionId,
      [
        {
          menuItemId: main.itemId,
          quantity: 2,
          modifierOptionIds: [modifier.optionId],
          notes: "No onion",
        },
        { menuItemId: drink.itemId, quantity: 1 },
      ],
      "Birthday table",
    );
    const orderId = String(order.orderId);
    const accepted = await transition(cashier.client, orderId, "accepted");
    expect(accepted.status).toBe("accepted");

    const board = await listBoard(kitchen.client, branchId);
    expect(board.tickets).toHaveLength(2);
    expect(board.pageSize).toBe(50);
    expect(board.hasMore).toBe(false);
    expect(board.nextOffset).toBeNull();

    const hotTicket = board.tickets.find(
      (ticket) => ticket.stationId === hotLine,
    )!;
    expect(hotTicket.stationName).toBeTruthy();
    expect(hotTicket.generation).toBe(1);
    const orderContext = hotTicket.order as Record<string, unknown>;
    expect(orderContext.orderId).toBe(orderId);
    expect(orderContext.orderReference).toBe(order.orderReference);
    expect(orderContext.status).toBe("accepted");
    expect(orderContext.source).toBe("staff");
    expect(orderContext.notes).toBe("Birthday table");
    expect(orderContext.tableLabel).toBe(tableLabel);

    const items = hotTicket.items as Array<Record<string, unknown>>;
    expect(items).toHaveLength(1);
    expect(items[0]!.name).toBeTruthy();
    expect(items[0]!.quantity).toBe(2);
    expect(items[0]!.notes).toBe("No onion");
    const modifiers = items[0]!.modifiers as Array<Record<string, unknown>>;
    expect(modifiers).toHaveLength(1);
    expect(modifiers[0]!.optionName).toBeTruthy();

    const keys = new Set<string>();
    collectKeys(board, keys);
    expect(
      [...keys].filter((key) =>
        /price|subtotal|discount|total|payment|currency/i.test(key),
      ),
    ).toEqual([]);

    const detail = await getTicket(kitchen.client, String(hotTicket.ticketId));
    expect(detail.ticketId).toBe(hotTicket.ticketId);
    expect((detail.order as Record<string, unknown>).tableLabel).toBe(
      tableLabel,
    );

    const stationFiltered = await listBoard(kitchen.client, branchId, {
      stationId: bar,
    });
    expect(stationFiltered.tickets).toHaveLength(1);
    expect(stationFiltered.tickets[0]!.stationId).toBe(bar);
  });

  it("supports status filters, bounded history, pagination, and empty boards", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const branchId = fixture.branchIds[0]!;
    const otherBranchId = fixture.branchIds[1]!;
    const owner = await createOwnerClient(fixture);
    const cashier = await createBranchStaff(admin, fixture, "cashier", [
      branchId,
    ]);
    const kitchen = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchId,
    ]);

    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("History item"),
    });
    const station = await createStation(
      owner,
      branchId,
      uniqueName("History station"),
    );
    await routeItem(owner, station, menu.itemId);

    const sessionId = await createSessionForBranch(
      admin,
      fixture,
      branchId,
      uniqueName("History table"),
    );
    const first = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const firstOrderId = String(first.orderId);
    await transition(cashier.client, firstOrderId, "accepted");
    const firstBoard = await listBoard(kitchen.client, branchId, {
      stationId: station,
    });
    const firstTicket = firstBoard.tickets[0]!;
    const firstItem = (firstTicket.items as Array<Record<string, unknown>>)[0]!;
    await startItem(kitchen.client, String(firstItem.ticketItemId));
    await readyItem(kitchen.client, String(firstItem.ticketItemId));
    await completeItem(kitchen.client, String(firstItem.ticketItemId));

    const activeOnly = await listBoard(kitchen.client, branchId, {
      stationId: station,
    });
    expect(
      activeOnly.tickets.some((ticket) => ticket.ticketId === firstTicket.ticketId),
    ).toBe(false);

    const from = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const to = new Date(Date.now() + 60 * 60 * 1000).toISOString();
    const history = await listBoard(kitchen.client, branchId, {
      stationId: station,
      statuses: ["completed"],
      from,
      to,
    });
    expect(
      history.tickets.some((ticket) => ticket.ticketId === firstTicket.ticketId),
    ).toBe(true);

    await expectPgError(
      listBoard(kitchen.client, branchId, {
        stationId: station,
        statuses: ["completed"],
      }),
      "VALIDATION_ERROR",
    );

    await expectPgError(
      listBoard(kitchen.client, branchId, {
        stationId: station,
        statuses: ["cancelled"],
        from: to,
        to: from,
      }),
      "VALIDATION_ERROR",
    );

    // A dedicated station keeps pagination deterministic and independent of
    // the completed ticket above.
    const pagingStation = await createStation(
      owner,
      branchId,
      uniqueName("Paging station"),
    );
    await routeItem(owner, pagingStation, menu.itemId);
    for (let index = 0; index < 3; index += 1) {
      const order = await createOrder(cashier.client, sessionId, [
        { menuItemId: menu.itemId, quantity: 1 },
      ]);
      await transition(cashier.client, String(order.orderId), "accepted");
    }

    const firstPage = await listBoard(kitchen.client, branchId, {
      stationId: pagingStation,
      limit: 2,
      offset: 0,
    });
    expect(firstPage.tickets).toHaveLength(2);
    expect(firstPage.hasMore).toBe(true);
    expect(firstPage.nextOffset).toBe(2);

    const secondPage = await listBoard(kitchen.client, branchId, {
      stationId: pagingStation,
      limit: 2,
      offset: 2,
    });
    expect(secondPage.tickets).toHaveLength(1);
    expect(secondPage.hasMore).toBe(false);
    expect(secondPage.nextOffset).toBeNull();

    const empty = await listBoard(owner, otherBranchId);
    expect(empty.tickets).toEqual([]);
    expect(empty.hasMore).toBe(false);
    expect(empty.nextOffset).toBeNull();
  });

  it("creates no tickets for unrouted items and keeps inactive stations readable", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const owner = await createOwnerClient(fixture);
    const cashier = await createBranchStaff(admin, fixture, "cashier", [
      branchId,
    ]);
    const kitchen = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchId,
    ]);
    const unrouted = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Unrouted item"),
    });
    const routed = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Routed item"),
    });
    const station = await createStation(
      owner,
      branchId,
      uniqueName("Readable inactive station"),
    );
    await routeItem(owner, station, routed.itemId);

    const sessionId = await createSessionForBranch(
      admin,
      fixture,
      branchId,
      uniqueName("Read table"),
    );
    const unroutedOrder = await createOrder(cashier.client, sessionId, [
      { menuItemId: unrouted.itemId, quantity: 1 },
    ]);
    await transition(cashier.client, String(unroutedOrder.orderId), "accepted");

    const routedOrder = await createOrder(cashier.client, sessionId, [
      { menuItemId: routed.itemId, quantity: 1 },
    ]);
    await transition(cashier.client, String(routedOrder.orderId), "accepted");

    const board = await listBoard(kitchen.client, branchId, {
      stationId: station,
    });
    expect(board.tickets).toHaveLength(1);
    expect(
      board.tickets.some(
        (ticket) =>
          (ticket.order as Record<string, unknown>).orderId ===
          unroutedOrder.orderId,
      ),
    ).toBe(false);

    await owner.query(
      "select public.deactivate_kitchen_station($1, $2)",
      [station, "Maintenance"],
    );
    const afterDeactivation = await listBoard(kitchen.client, branchId, {
      stationId: station,
    });
    expect(afterDeactivation.tickets).toHaveLength(1);
    expect(afterDeactivation.tickets[0]!.stationName).toBeTruthy();
  });

  it("enforces branch, role, and cross-organization boundaries", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const branchA = fixture.branchIds[0]!;
    const branchB = fixture.branchIds[1]!;
    const owner = await createOwnerClient(fixture);
    const cashier = await createBranchStaff(admin, fixture, "cashier", [
      branchA,
    ]);
    const kitchenA = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchA,
    ]);
    const kitchenB = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchB,
    ]);
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Boundary item"),
    });
    const station = await createStation(owner, branchA, uniqueName("Boundary station"));
    await routeItem(owner, station, menu.itemId);

    const sessionId = await createSessionForBranch(
      admin,
      fixture,
      branchA,
      uniqueName("Boundary table"),
    );
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    await transition(cashier.client, String(order.orderId), "accepted");
    const board = await listBoard(kitchenA.client, branchA, {
      stationId: station,
    });
    const ticketId = String(board.tickets[0]!.ticketId);

    await expectPgError(
      listBoard(cashier.client, branchA),
      "PERMISSION_DENIED",
    );
    await expectPgError(
      listBoard(kitchenB.client, branchA),
      "PERMISSION_DENIED",
    );

    const otherOrg = await createOrgFixture(admin, { branchCount: 1 });
    const otherOwner = await createOwnerClient(otherOrg);
    await expectPgError(
      listBoard(otherOwner, branchA),
      "BRANCH_NOT_FOUND",
    );
    await expectPgError(
      getTicket(otherOwner, ticketId),
      "KITCHEN_TICKET_NOT_FOUND",
    );
  });
});
