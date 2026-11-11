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
  listRoutingIssues,
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

type MenuItem = { categoryId: string; itemId: string };

const createMenuItem = async (
  admin: pg.Client,
  options: { organizationId: string; name: string },
): Promise<MenuItem> => {
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

const createStation = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    name: string;
    status?: "active" | "inactive";
    deactivatedAt?: string | null;
  },
): Promise<string> => {
  const status = options.status ?? "active";
  const deactivatedAt =
    options.deactivatedAt === undefined
      ? status === "inactive"
        ? new Date().toISOString()
        : null
      : options.deactivatedAt;
  const result = await admin.query<{ id: string }>(
    `insert into public.kitchen_stations
       (organization_id, branch_id, name, status, deactivated_at)
     values ($1, $2, $3, $4::public.kitchen_station_status, $5)
     returning id`,
    [
      options.organizationId,
      options.branchId,
      options.name,
      status,
      deactivatedAt,
    ],
  );
  return result.rows[0]!.id;
};

const routeItem = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    stationId: string;
    menuItemId: string;
  },
): Promise<void> => {
  await admin.query(
    `insert into public.kitchen_station_menu_items
       (organization_id, branch_id, station_id, menu_item_id)
     values ($1, $2, $3, $4)`,
    [
      options.organizationId,
      options.branchId,
      options.stationId,
      options.menuItemId,
    ],
  );
};

const routeCategory = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    stationId: string;
    menuCategoryId: string;
  },
): Promise<void> => {
  await admin.query(
    `insert into public.kitchen_station_menu_categories
       (organization_id, branch_id, station_id, menu_category_id)
     values ($1, $2, $3, $4)`,
    [
      options.organizationId,
      options.branchId,
      options.stationId,
      options.menuCategoryId,
    ],
  );
};

const createDiningSession = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    tableId: string;
    staffId: string;
  },
): Promise<string> => {
  const result = await admin.query<{ id: string }>(
    `insert into public.dining_sessions
       (organization_id, branch_id, table_id, opened_by_staff_id)
     values ($1, $2, $3, $4)
     returning id`,
    [
      options.organizationId,
      options.branchId,
      options.tableId,
      options.staffId,
    ],
  );
  return result.rows[0]!.id;
};

const createOrder = async (
  client: pg.Client,
  sessionId: string,
  items: Array<{ menuItemId: string; quantity?: number }>,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.create_order($1, $2::jsonb, null, null) as result",
    [sessionId, JSON.stringify(items)],
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

const addOrderItem = async (
  client: pg.Client,
  orderId: string,
  menuItemId: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.add_order_item($1, $2, 1, '{}'::uuid[], null) as result",
    [orderId, menuItemId],
  );
  return result.rows[0]!.result;
};

const removeOrderItem = async (
  client: pg.Client,
  orderItemId: string,
  reason: string,
): Promise<Record<string, unknown>> => {
  const result = await client.query<{ result: Record<string, unknown> }>(
    "select public.remove_order_item($1, $2) as result",
    [orderItemId, reason],
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

type TicketRow = {
  id: string;
  station_id: string;
  generation: number;
  status: string;
  started_at: Date | null;
  ready_at: Date | null;
  completed_at: Date | null;
  cancelled_at: Date | null;
  cancelled_by_actor_type: string;
  cancelled_by_staff_id: string | null;
  cancellation_reason: string | null;
};

type TicketItemRow = {
  id: string;
  ticket_id: string;
  order_item_id: string;
  order_id: string;
  menu_item_id: string;
  status: string;
  started_at: Date | null;
  ready_at: Date | null;
  completed_at: Date | null;
  cancelled_at: Date | null;
  cancelled_by_actor_type: string;
  cancelled_by_staff_id: string | null;
  cancellation_reason: string | null;
};

const listTickets = async (
  admin: pg.Client,
  orderId: string,
): Promise<TicketRow[]> => {
  const result = await admin.query<TicketRow>(
    `select id, station_id, generation, status::text, started_at, ready_at,
            completed_at, cancelled_at, cancelled_by_actor_type,
            cancelled_by_staff_id, cancellation_reason
       from public.kitchen_tickets
      where order_id = $1
      order by station_id, generation`,
    [orderId],
  );
  return result.rows;
};

const listTicketItems = async (
  admin: pg.Client,
  orderId: string,
): Promise<TicketItemRow[]> => {
  const result = await admin.query<TicketItemRow>(
    `select ti.id, ti.ticket_id, ti.order_item_id, ti.order_id,
            oi.menu_item_id, ti.status::text, ti.started_at, ti.ready_at,
            ti.completed_at, ti.cancelled_at, ti.cancelled_by_actor_type,
            ti.cancelled_by_staff_id, ti.cancellation_reason
       from public.kitchen_ticket_items ti
       join public.order_items oi on oi.id = ti.order_item_id
      where ti.order_id = $1
      order by oi.created_at, ti.id`,
    [orderId],
  );
  return result.rows;
};

type TicketItemWithStation = TicketItemRow & { station_id: string };

const listTicketItemsWithStations = async (
  admin: pg.Client,
  orderId: string,
): Promise<TicketItemWithStation[]> => {
  const result = await admin.query<TicketItemWithStation>(
    `select ti.id, ti.ticket_id, ti.order_item_id, ti.order_id,
            oi.menu_item_id, ti.status::text, ti.started_at, ti.ready_at,
            ti.completed_at, ti.cancelled_at, ti.cancelled_by_actor_type,
            ti.cancelled_by_staff_id, ti.cancellation_reason,
            t.station_id
       from public.kitchen_ticket_items ti
       join public.order_items oi on oi.id = ti.order_item_id
       join public.kitchen_tickets t on t.id = ti.ticket_id
      where ti.order_id = $1
      order by oi.created_at, ti.id`,
    [orderId],
  );
  return result.rows;
};

const ticketItemForMenuItem = async (
  admin: pg.Client,
  orderId: string,
  menuItemId: string,
): Promise<TicketItemRow> => {
  const items = await listTicketItems(admin, orderId);
  const item = items.find((row) => row.menu_item_id === menuItemId);
  if (!item) {
    throw new Error(`No kitchen ticket item found for menu item ${menuItemId}`);
  }
  return item;
};

const orderItemsFromResponse = (
  response: Record<string, unknown>,
): Array<Record<string, unknown>> => response.items as Array<Record<string, unknown>>;

const orderItemIdForMenuItem = (
  response: Record<string, unknown>,
  menuItemId: string,
): string => {
  const item = orderItemsFromResponse(response).find(
    (row) => row.menuItemId === menuItemId,
  );
  if (!item) {
    throw new Error(`No order item found for menu item ${menuItemId}`);
  }
  return item.orderItemId as string;
};

const newOrderItemIdForMenuItem = (
  response: Record<string, unknown>,
  menuItemId: string,
  previousOrderItemId: string,
): string => {
  const item = orderItemsFromResponse(response).find(
    (row) =>
      row.menuItemId === menuItemId &&
      row.orderItemId !== previousOrderItemId &&
      row.status !== "cancelled",
  );
  if (!item) {
    throw new Error(`No replacement order item found for menu item ${menuItemId}`);
  }
  return item.orderItemId as string;
};

const createSessionForBranch = async (
  admin: pg.Client,
  fixture: Fixture,
  branchId: string,
): Promise<string> => {
  const table = await createTable(admin, {
    organizationId: fixture.organizationId,
    branchId,
    label: uniqueName("M4 table"),
  });
  return createDiningSession(admin, {
    organizationId: fixture.organizationId,
    branchId,
    tableId: table.tableId,
    staffId: fixture.ownerStaffId,
  });
};

const createCashier = async (
  admin: pg.Client,
  fixture: Fixture,
  branchId: string,
): Promise<{ client: pg.Client; staffId: string; authUserId: string }> => {
  const staff = await addStaff(admin, {
    organizationId: fixture.organizationId,
    role: "cashier",
    scope: "branch",
    branchIds: [branchId],
  });
  const client = await createClient();
  track(client);
  await authenticateAs(client, staff.authUserId);
  return { client, ...staff };
};

const createKitchenStaff = async (
  admin: pg.Client,
  fixture: Fixture,
  branchIds: string[],
): Promise<{ client: pg.Client; staffId: string; authUserId: string }> => {
  const staff = await addStaff(admin, {
    organizationId: fixture.organizationId,
    role: "kitchen_staff",
    scope: "branch",
    branchIds,
  });
  const client = await createClient();
  track(client);
  await authenticateAs(client, staff.authUserId);
  return { client, ...staff };
};

const createManager = async (
  admin: pg.Client,
  fixture: Fixture,
  branchIds: string[],
): Promise<{ client: pg.Client; staffId: string; authUserId: string }> => {
  const staff = await addStaff(admin, {
    organizationId: fixture.organizationId,
    role: "manager",
    scope: "branch",
    branchIds,
  });
  const client = await createClient();
  track(client);
  await authenticateAs(client, staff.authUserId);
  return { client, ...staff };
};

describe("M4.2 ticket generation", () => {
  it("creates one ticket and one item for a single routed item on acceptance", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Soup"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Hot line"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;

    expect(await listTickets(admin, orderId)).toHaveLength(0);

    const accepted = await transition(cashier.client, orderId, "accepted");
    expect(accepted.status).toBe("accepted");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(1);
    expect(tickets[0]!.station_id).toBe(station);
    expect(tickets[0]!.status).toBe("pending");

    const items = await listTicketItems(admin, orderId);
    expect(items).toHaveLength(1);
    expect(items[0]!.menu_item_id).toBe(menu.itemId);
    expect(items[0]!.status).toBe("pending");
    expect(items[0]!.ticket_id).toBe(tickets[0]!.id);
  });

  it("groups multiple items routed to the same station onto one ticket", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const soup = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Soup"),
    });
    const steak = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Steak"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Hot line"),
    });
    for (const menu of [soup, steak]) {
      await routeItem(admin, {
        organizationId: fixture.organizationId,
        branchId,
        stationId: station,
        menuItemId: menu.itemId,
      });
    }
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: soup.itemId, quantity: 2 },
      { menuItemId: steak.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(1);
    expect(tickets[0]!.station_id).toBe(station);
    expect(await listTicketItems(admin, orderId)).toHaveLength(2);
  });

  it("creates separate tickets for items routed to different stations", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const salad = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Salad"),
    });
    const steak = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Steak"),
    });
    const cold = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Cold line"),
    });
    const hot = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Hot line"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: cold,
      menuItemId: salad.itemId,
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: hot,
      menuItemId: steak.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: salad.itemId, quantity: 1 },
      { menuItemId: steak.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(2);
    expect(tickets.map((row) => row.station_id).sort()).toEqual(
      [cold, hot].sort(),
    );

    const items = await listTicketItems(admin, orderId);
    expect(items.find((row) => row.menu_item_id === salad.itemId)?.ticket_id).toBe(
      tickets.find((row) => row.station_id === cold)?.id,
    );
    expect(items.find((row) => row.menu_item_id === steak.itemId)?.ticket_id).toBe(
      tickets.find((row) => row.station_id === hot)?.id,
    );
  });

  it("uses item-level routing in preference to category routing", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Overridden item"),
    });
    const itemStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Item station"),
    });
    const categoryStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Category station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: itemStation,
      menuItemId: menu.itemId,
    });
    await routeCategory(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: categoryStation,
      menuCategoryId: menu.categoryId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(1);
    expect(tickets[0]!.station_id).toBe(itemStation);
  });

  it("falls back to category routing when no item-level route exists", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Category routed"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Category station"),
    });
    await routeCategory(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuCategoryId: menu.categoryId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(1);
    expect(tickets[0]!.station_id).toBe(station);
  });

  it("accepts an order with unrouted items without creating tickets", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Unrouted"),
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;

    const accepted = await transition(cashier.client, orderId, "accepted");
    expect(accepted.status).toBe("accepted");
    expect(await listTickets(admin, orderId)).toHaveLength(0);

    const items = await admin.query<{ status: string }>(
      "select status::text from public.order_items where order_id = $1",
      [orderId],
    );
    expect(items.rows[0]!.status).toBe("accepted");
  });

  it("skips inactive stations and does not fall back past item-level routing", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const inactiveItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Inactive item route"),
    });
    const inactiveOnly = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Inactive only"),
    });
    const inactiveStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Inactive station"),
      status: "inactive",
    });
    const activeCategoryStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Active category station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: inactiveStation,
      menuItemId: inactiveItem.itemId,
    });
    await routeCategory(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: activeCategoryStation,
      menuCategoryId: inactiveItem.categoryId,
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: inactiveStation,
      menuItemId: inactiveOnly.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: inactiveItem.itemId, quantity: 1 },
      { menuItemId: inactiveOnly.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    // The item-level route exists but is inactive. Category routing is not a
    // fallback once item-level routing has been configured.
    expect(await listTickets(admin, orderId)).toHaveLength(0);
  });

  it("does not route an order through a station in another branch", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Scoped route"),
    });
    const otherBranchStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      name: uniqueName("Other branch station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      stationId: otherBranchStation,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchA!);
    const cashier = await createCashier(admin, fixture, branchA!);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    expect(await listTickets(admin, orderId)).toHaveLength(0);
  });
});

describe("M4.2 generation idempotency and concurrency", () => {
  it("does not duplicate tickets on repeated acceptance and routes only new accepted items", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const first = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("First"),
    });
    const second = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Second"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Station"),
    });
    for (const menu of [first, second]) {
      await routeItem(admin, {
        organizationId: fixture.organizationId,
        branchId,
        stationId: station,
        menuItemId: menu.itemId,
      });
    }
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: first.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const before = await listTickets(admin, orderId);
    expect(before).toHaveLength(1);
    expect(await listTicketItems(admin, orderId)).toHaveLength(1);

    await expectPgError(
      transition(cashier.client, orderId, "accepted"),
      "ORDER_INVALID_STATUS",
    );

    const afterRepeat = await listTickets(admin, orderId);
    expect(afterRepeat.map((row) => row.id)).toEqual(
      before.map((row) => row.id),
    );
    expect(await listTicketItems(admin, orderId)).toHaveLength(1);

    // Adding an item while accepted creates only the new ticket item and
    // preserves the existing ticket identity.
    await addOrderItem(cashier.client, orderId, second.itemId);
    const afterAdd = await listTickets(admin, orderId);
    expect(afterAdd.map((row) => row.id)).toEqual(
      before.map((row) => row.id),
    );
    const items = await listTicketItems(admin, orderId);
    expect(items).toHaveLength(2);
    expect(items.map((row) => row.menu_item_id).sort()).toEqual(
      [first.itemId, second.itemId].sort(),
    );
  });

  it("handles concurrent acceptance without duplicate tickets or ticket items", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const salad = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Concurrent salad"),
    });
    const steak = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Concurrent steak"),
    });
    const cold = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Concurrent cold"),
    });
    const hot = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Concurrent hot"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: cold,
      menuItemId: salad.itemId,
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: hot,
      menuItemId: steak.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashierOne = await createCashier(admin, fixture, branchId);
    const cashierTwo = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashierOne.client, sessionId, [
      { menuItemId: salad.itemId, quantity: 1 },
      { menuItemId: steak.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;

    const results = await Promise.allSettled([
      transition(cashierOne.client, orderId, "accepted"),
      transition(cashierTwo.client, orderId, "accepted"),
    ]);

    const fulfilled = results.filter((result) => result.status === "fulfilled");
    const rejected = results.filter((result) => result.status === "rejected");
    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    const message = String(
      (rejected[0] as PromiseRejectedResult).reason,
    );
    expect(message).toContain("ORDER_INVALID_STATUS");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(2);
    expect(new Set(tickets.map((row) => row.station_id)).size).toBe(2);

    const items = await listTicketItems(admin, orderId);
    expect(items).toHaveLength(2);
    expect(new Set(items.map((row) => row.order_item_id)).size).toBe(2);
  });
});

describe("M4.2 ticket-item lifecycle", () => {
  const setupSingleItem = async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Lifecycle item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Lifecycle station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const ticketItem = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    return { admin, fixture, branchId, menu, station, cashier, kitchen, orderId, ticketItem };
  };

  it("supports pending -> preparing -> ready -> completed", async () => {
    const { admin, kitchen, menu, orderId, ticketItem } =
      await setupSingleItem();

    const preparing = await startItem(kitchen.client, ticketItem.id);
    expect(preparing.status).toBe("preparing");
    expect((preparing.items as Array<Record<string, unknown>>)[0]!.status).toBe(
      "preparing",
    );

    const ready = await readyItem(kitchen.client, ticketItem.id);
    expect(ready.status).toBe("ready");

    const completed = await completeItem(kitchen.client, ticketItem.id);
    expect(completed.status).toBe("completed");

    const tickets = await listTickets(admin, orderId);
    expect(tickets[0]!.status).toBe("completed");
    expect(tickets[0]!.started_at).not.toBeNull();
    expect(tickets[0]!.ready_at).not.toBeNull();
    expect(tickets[0]!.completed_at).not.toBeNull();

    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    expect(item.status).toBe("completed");
    expect(item.started_at).not.toBeNull();
    expect(item.ready_at).not.toBeNull();
    expect(item.completed_at).not.toBeNull();

    // Cashier-controlled order state is untouched by kitchen progress.
    const orderStatus = await admin.query<{ status: string }>(
      "select status::text from public.orders where id = $1",
      [orderId],
    );
    expect(orderStatus.rows[0]!.status).toBe("accepted");

    // Repeated identical requests are safe no-ops.
    const repeated = await completeItem(kitchen.client, ticketItem.id);
    expect(repeated.status).toBe("completed");
  });

  it("rejects skipped and backward transitions", async () => {
    const { admin, kitchen, menu, orderId, ticketItem } =
      await setupSingleItem();

    await expectPgError(
      readyItem(kitchen.client, ticketItem.id),
      "KITCHEN_INVALID_TRANSITION",
    );
    await expectPgError(
      completeItem(kitchen.client, ticketItem.id),
      "KITCHEN_INVALID_TRANSITION",
    );

    await startItem(kitchen.client, ticketItem.id);
    await expectPgError(
      completeItem(kitchen.client, ticketItem.id),
      "KITCHEN_INVALID_TRANSITION",
    );
    await readyItem(kitchen.client, ticketItem.id);
    await expectPgError(
      startItem(kitchen.client, ticketItem.id),
      "KITCHEN_INVALID_TRANSITION",
    );
    await completeItem(kitchen.client, ticketItem.id);
    await expectPgError(
      readyItem(kitchen.client, ticketItem.id),
      "KITCHEN_INVALID_TRANSITION",
    );

    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    expect(item.status).toBe("completed");
  });

  it("aggregates a shared ticket from independent item progress", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const soup = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Aggregate soup"),
    });
    const steak = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Aggregate steak"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Aggregate station"),
    });
    for (const menu of [soup, steak]) {
      await routeItem(admin, {
        organizationId: fixture.organizationId,
        branchId,
        stationId: station,
        menuItemId: menu.itemId,
      });
    }
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: soup.itemId, quantity: 1 },
      { menuItemId: steak.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");

    const soupItem = await ticketItemForMenuItem(admin, orderId, soup.itemId);
    const steakItem = await ticketItemForMenuItem(admin, orderId, steak.itemId);

    expect((await listTickets(admin, orderId))[0]!.status).toBe("pending");

    await startItem(kitchen.client, soupItem.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("preparing");

    await startItem(kitchen.client, steakItem.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("preparing");

    await readyItem(kitchen.client, soupItem.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("preparing");

    await readyItem(kitchen.client, steakItem.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("ready");

    await completeItem(kitchen.client, soupItem.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("ready");

    await completeItem(kitchen.client, steakItem.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("completed");
  });

  it("enforces kitchen authorization and tenant/branch isolation", async () => {
    const { admin, fixture, branchIds, cashier, kitchen, orderId, ticketItem } =
      await (async () => {
        const adminClient = await createClient();
        track(adminClient);
        const org = await createOrgFixture(adminClient, { branchCount: 2 });
        const branchA = org.branchIds[0]!;
        const branchB = org.branchIds[1]!;
        const menuFixture = await createMenuItem(adminClient, {
          organizationId: org.organizationId,
          name: uniqueName("Authz item"),
        });
        const station = await createStation(adminClient, {
          organizationId: org.organizationId,
          branchId: branchA,
          name: uniqueName("Authz station"),
        });
        await routeItem(adminClient, {
          organizationId: org.organizationId,
          branchId: branchA,
          stationId: station,
          menuItemId: menuFixture.itemId,
        });
        const sessionId = await createSessionForBranch(
          adminClient,
          org,
          branchA,
        );
        const cashierFixture = await createCashier(adminClient, org, branchA);
        const kitchenFixture = await createKitchenStaff(adminClient, org, [
          branchA,
        ]);
        const order = await createOrder(cashierFixture.client, sessionId, [
          { menuItemId: menuFixture.itemId, quantity: 1 },
        ]);
        const id = order.orderId as string;
        await transition(cashierFixture.client, id, "accepted");
        return {
          admin: adminClient,
          fixture: org,
          branchIds: [branchA, branchB],
          cashier: cashierFixture,
          kitchen: kitchenFixture,
          menu: menuFixture,
          orderId: id,
          ticketItem: await ticketItemForMenuItem(
            adminClient,
            id,
            menuFixture.itemId,
          ),
        };
      })();

    // Cashier is an order operator, not a kitchen operator.
    await expectPgError(
      startItem(cashier.client, ticketItem.id),
      "PERMISSION_DENIED",
    );

    const kitchenOtherBranch = await createKitchenStaff(admin, fixture, [
      branchIds[1]!,
    ]);
    await expectPgError(
      startItem(kitchenOtherBranch.client, ticketItem.id),
      "PERMISSION_DENIED",
    );

    const otherOrg = await createOrgFixture(admin, { branchCount: 1 });
    const otherOwner = await createClient();
    track(otherOwner);
    await authenticateAs(otherOwner, otherOrg.ownerAuthUserId);
    await expectPgError(
      startItem(otherOwner, ticketItem.id),
      "KITCHEN_TICKET_ITEM_NOT_FOUND",
    );

    const anon = await createClient();
    track(anon);
    await anon.query("set role anon");
    await expectPgError(
      startItem(anon, ticketItem.id),
      "permission denied",
    );

    // Manager, Kitchen Staff, and Owner can each operate kitchen state within
    // the branch.
    const manager = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchIds[0]!],
    });
    const managerClient = await createClient();
    const ownerClient = await createClient();
    track(managerClient, ownerClient);
    await authenticateAs(managerClient, manager.authUserId);
    await authenticateAs(ownerClient, fixture.ownerAuthUserId);

    await startItem(managerClient, ticketItem.id);
    await readyItem(kitchen.client, ticketItem.id);
    const completed = await completeItem(ownerClient, ticketItem.id);
    expect(completed.status).toBe("completed");

    // Direct table writes remain denied even for kitchen staff.
    await expectPgError(
      kitchen.client.query(
        "update public.kitchen_tickets set status = 'ready' where order_id = $1",
        [orderId],
      ),
      "permission denied",
    );
    await expectPgError(
      kitchen.client.query(
        "update public.kitchen_ticket_items set status = 'ready' where id = $1",
        [ticketItem.id],
      ),
      "permission denied",
    );
    await expectPgError(
      kitchen.client.query(
        `insert into public.kitchen_ticket_items
           (organization_id, branch_id, ticket_id, order_id, order_item_id)
         values ($1, $2, $3, $4, $5)`,
        [
          fixture.organizationId,
          branchIds[0],
          ticketItem.ticket_id,
          orderId,
          ticketItem.order_item_id,
        ],
      ),
      "permission denied",
    );
  });
});

describe("M4.2 cancellation and station deactivation", () => {
  it("propagates order cancellation to tickets and ticket items without completing them", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Cancel item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Cancel station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, item.id);

    await cancelOrder(cashier.client, orderId, "Guest left");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(1);
    expect(tickets[0]!.status).toBe("cancelled");
    expect(tickets[0]!.cancelled_at).not.toBeNull();
    expect(tickets[0]!.cancelled_by_staff_id).toBe(cashier.staffId);
    expect(tickets[0]!.cancellation_reason).toBe("Guest left");

    const items = await listTicketItems(admin, orderId);
    expect(items[0]!.status).toBe("cancelled");
    expect(items[0]!.cancelled_by_staff_id).toBe(cashier.staffId);
    expect(items[0]!.cancellation_reason).toBe("Guest left");
    expect(items[0]!.completed_at).toBeNull();

    await expectPgError(
      completeItem(kitchen.client, item.id),
      "KITCHEN_TICKET_CANCELLED",
    );
  });

  it("cancels only the affected ticket when one order item is removed", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const soup = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Removed soup"),
    });
    const steak = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Kept steak"),
    });
    const soupStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Soup station"),
    });
    const steakStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Steak station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: soupStation,
      menuItemId: soup.itemId,
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: steakStation,
      menuItemId: steak.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: soup.itemId, quantity: 1 },
      { menuItemId: steak.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const soupOrderItemId = orderItemIdForMenuItem(order, soup.itemId);
    await transition(cashier.client, orderId, "accepted");

    await removeOrderItem(cashier.client, soupOrderItemId, "Guest changed order");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(2);
    expect(
      tickets.find((row) => row.station_id === soupStation)?.status,
    ).toBe("cancelled");
    expect(
      tickets.find((row) => row.station_id === steakStation)?.status,
    ).toBe("pending");

    const items = await listTicketItems(admin, orderId);
    expect(
      items.find((row) => row.menu_item_id === soup.itemId)?.status,
    ).toBe("cancelled");
    expect(
      items.find((row) => row.menu_item_id === steak.itemId)?.status,
    ).toBe("pending");
  });

  it("allows existing tickets to be completed after station deactivation and skips it for new routing", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Deactivation item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Deactivation station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const firstOrder = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const firstOrderId = firstOrder.orderId as string;
    await transition(cashier.client, firstOrderId, "accepted");
    const existingItem = await ticketItemForMenuItem(
      admin,
      firstOrderId,
      menu.itemId,
    );

    await admin.query(
      `update public.kitchen_stations
          set status = 'inactive', deactivated_at = now()
        where id = $1`,
      [station],
    );

    // Deactivation does not cancel existing work.
    expect((await listTickets(admin, firstOrderId))[0]!.status).toBe("pending");

    // Kitchen staff can still read and complete the existing ticket.
    const visible = await kitchen.client.query<{ status: string }>(
      "select status::text from public.kitchen_tickets where order_id = $1",
      [firstOrderId],
    );
    expect(visible.rows[0]!.status).toBe("pending");

    await startItem(kitchen.client, existingItem.id);
    await readyItem(kitchen.client, existingItem.id);
    const completed = await completeItem(kitchen.client, existingItem.id);
    expect(completed.status).toBe("completed");

    const secondOrder = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const secondOrderId = secondOrder.orderId as string;
    await transition(cashier.client, secondOrderId, "accepted");
    expect(await listTickets(admin, secondOrderId)).toHaveLength(0);
  });
});

describe("M4.2 order lifecycle compatibility and guards", () => {
  it("keeps an unrouted order accept-able and completable through the M3 lifecycle", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("No kitchen"),
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);
    const manager = await createManager(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;

    expect((await transition(cashier.client, orderId, "accepted")).status).toBe(
      "accepted",
    );
    await expectPgError(
      transition(kitchen.client, orderId, "preparing"),
      "PERMISSION_DENIED",
    );
    await expectPgError(
      transition(kitchen.client, orderId, "ready"),
      "PERMISSION_DENIED",
    );
    expect((await transition(manager.client, orderId, "preparing")).status).toBe(
      "preparing",
    );
    expect((await transition(manager.client, orderId, "ready")).status).toBe(
      "ready",
    );
    expect((await transition(cashier.client, orderId, "served")).status).toBe(
      "served",
    );
    const completed = await transition(cashier.client, orderId, "completed");
    expect(completed.status).toBe("completed");
    expect(completed.completedAt).not.toBeNull();
    expect(await listTickets(admin, orderId)).toHaveLength(0);
  });

  it("does not let kitchen progress rewrite order state and does not let the M3 cascade overwrite kitchen progress", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Independent state"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Independent station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);
    const manager = await createManager(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);

    await startItem(kitchen.client, item.id);
    await readyItem(kitchen.client, item.id);
    await completeItem(kitchen.client, item.id);

    const orderAfterKitchen = await admin.query<{ status: string }>(
      "select status::text from public.orders where id = $1",
      [orderId],
    );
    expect(orderAfterKitchen.rows[0]!.status).toBe("accepted");

    await expectPgError(
      transition(kitchen.client, orderId, "preparing"),
      "PERMISSION_DENIED",
    );
    await expectPgError(
      transition(kitchen.client, orderId, "ready"),
      "PERMISSION_DENIED",
    );

    await transition(manager.client, orderId, "preparing");
    await transition(manager.client, orderId, "ready");
    await transition(cashier.client, orderId, "served");
    await transition(cashier.client, orderId, "completed");

    const kitchenItem = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    expect(kitchenItem.status).toBe("completed");
    expect(kitchenItem.completed_at).not.toBeNull();
    expect((await listTickets(admin, orderId))[0]!.status).toBe("completed");
  });

  it("rejects direct privileged ticket updates that bypass item state", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Guard item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Guard station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    const ticket = (await listTickets(admin, orderId))[0]!;

    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set status = 'completed' where id = $1",
        [ticket.id],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );
    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set status = 'ready' where id = $1",
        [ticket.id],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );

    await expectPgError(
      admin.query(
        "update public.kitchen_ticket_items set status = 'ready' where id = $1",
        [item.id],
      ),
      "KITCHEN_INVALID_TRANSITION",
    );
    await expectPgError(
      admin.query(
        "update public.kitchen_ticket_items set status = 'completed' where id = $1",
        [item.id],
      ),
      "KITCHEN_INVALID_TRANSITION",
    );
  });

  it("records audit events for ticket creation, item transitions, and cancellation", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Audit item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Audit station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, item.id);
    await readyItem(kitchen.client, item.id);
    await completeItem(kitchen.client, item.id);

    const audit = await admin.query<{
      action: string;
      actor_id: string | null;
      target_type: string;
      target_id: string | null;
      metadata: Record<string, unknown>;
    }>(
      `select action, actor_id, target_type, target_id, metadata
         from public.audit_events
        where organization_id = $1
          and action like 'kitchen.%'
        order by created_at, id`,
      [fixture.organizationId],
    );

    const actions = audit.rows.map((row) => row.action);
    expect(actions).toContain("kitchen.ticket_created");
    expect(actions).toContain("kitchen.ticket_item_status_changed");
    expect(actions).toContain("kitchen.ticket_status_changed");

    const created = audit.rows.find(
      (row) => row.action === "kitchen.ticket_created",
    );
    expect(created?.actor_id).toBe(cashier.staffId);
    expect(created?.target_type).toBe("kitchen_ticket");

    const itemTransitions = audit.rows.filter(
      (row) => row.action === "kitchen.ticket_item_status_changed",
    );
    expect(itemTransitions.map((row) => row.metadata.to_status)).toEqual([
      "preparing",
      "ready",
      "completed",
    ]);
    for (const row of itemTransitions) {
      expect(row.actor_id).toBe(kitchen.staffId);
    }
  });
});

describe("M4.2 corrective ticket identity", () => {
  it("creates a fresh active ticket after the last item at a station was cancelled", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Regenerated item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Regeneration station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const firstOrderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");

    expect(await listTickets(admin, orderId)).toHaveLength(1);
    await removeOrderItem(cashier.client, firstOrderItemId, "Guest changed order");

    const afterRemoval = await listTickets(admin, orderId);
    expect(afterRemoval).toHaveLength(1);
    expect(afterRemoval[0]!.status).toBe("cancelled");
    expect(afterRemoval[0]!.generation).toBe(1);

    const withReplacement = await addOrderItem(
      cashier.client,
      orderId,
      menu.itemId,
    );
    const secondOrderItemId = newOrderItemIdForMenuItem(
      withReplacement,
      menu.itemId,
      firstOrderItemId,
    );

    const afterReplacement = await listTickets(admin, orderId);
    expect(afterReplacement).toHaveLength(2);
    const historical = afterReplacement.find((row) => row.generation === 1)!;
    const active = afterReplacement.find((row) => row.generation === 2)!;
    expect(historical.status).toBe("cancelled");
    expect(active.status).toBe("pending");
    expect(active.station_id).toBe(station);

    const items = await listTicketItems(admin, orderId);
    expect(items).toHaveLength(2);
    expect(
      items.find((row) => row.order_item_id === firstOrderItemId)?.status,
    ).toBe("cancelled");
    const replacementItem = items.find(
      (row) => row.order_item_id === secondOrderItemId,
    );
    expect(replacementItem?.status).toBe("pending");
    expect(replacementItem?.ticket_id).toBe(active.id);

    // Regeneration is idempotent: repeating generation for the same added item
    // must not create another ticket or ticket item.
    await admin.query("select private.generate_kitchen_tickets($1, $2)", [
      orderId,
      secondOrderItemId,
    ]);
    expect(await listTickets(admin, orderId)).toHaveLength(2);
    expect(await listTicketItems(admin, orderId)).toHaveLength(2);

    // The replacement work is usable by the kitchen.
    await startItem(kitchen.client, replacementItem!.id);
    const activeAfterStart = (await listTickets(admin, orderId)).find(
      (row) => row.id === active.id,
    )!;
    expect(activeAfterStart.status).toBe("preparing");
    expect(historical.status).toBe("cancelled");
  });
});

describe("M4.2 exact ticket aggregate guard", () => {
  it("rejects direct cancellation while active items remain and direct inconsistent aggregates", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Guard item"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Guard station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const ticket = (await listTickets(admin, orderId))[0]!;
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);

    await expectPgError(
      admin.query(
        `update public.kitchen_tickets
            set status = 'cancelled',
                cancelled_at = now(),
                cancelled_by_actor_type = 'staff',
                cancelled_by_staff_id = $2,
                cancellation_reason = 'Direct cancellation'
          where id = $1`,
        [ticket.id, cashier.staffId],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );

    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set status = 'ready' where id = $1",
        [ticket.id],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );

    await startItem(kitchen.client, item.id);
    await readyItem(kitchen.client, item.id);
    await completeItem(kitchen.client, item.id);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("completed");

    // The old guard allowed completed -> preparing because it only required one
    // started item. The exact aggregate guard must reject this.
    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set status = 'preparing' where id = $1",
        [ticket.id],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );
    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set status = 'pending' where id = $1",
        [ticket.id],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );

    const persisted = (await listTickets(admin, orderId))[0]!;
    expect(persisted.status).toBe("completed");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "completed",
    );
  });
});

describe("M4.2 completed-item removal policy", () => {
  it("allows removal while the item is pending, preparing, or ready", async () => {
    for (const state of ["pending", "preparing", "ready"] as const) {
      const admin = await createClient();
      track(admin);
      const fixture = await createOrgFixture(admin, { branchCount: 1 });
      const branchId = fixture.branchIds[0]!;
      const menu = await createMenuItem(admin, {
        organizationId: fixture.organizationId,
        name: uniqueName(`Removable ${state}`),
      });
      const station = await createStation(admin, {
        organizationId: fixture.organizationId,
        branchId,
        name: uniqueName(`Removable station ${state}`),
      });
      await routeItem(admin, {
        organizationId: fixture.organizationId,
        branchId,
        stationId: station,
        menuItemId: menu.itemId,
      });
      const sessionId = await createSessionForBranch(
        admin,
        fixture,
        branchId,
      );
      const cashier = await createCashier(admin, fixture, branchId);
      const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

      const order = await createOrder(cashier.client, sessionId, [
        { menuItemId: menu.itemId, quantity: 1 },
      ]);
      const orderId = order.orderId as string;
      const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
      await transition(cashier.client, orderId, "accepted");
      const ticketItem = await ticketItemForMenuItem(
        admin,
        orderId,
        menu.itemId,
      );

      if (state !== "pending") {
        await startItem(kitchen.client, ticketItem.id);
      }
      if (state === "ready") {
        await readyItem(kitchen.client, ticketItem.id);
      }

      await removeOrderItem(
        cashier.client,
        orderItemId,
        `Remove ${state} item`,
      );

      const orderItem = await admin.query<{ status: string }>(
        "select status::text from public.order_items where id = $1",
        [orderItemId],
      );
      expect(orderItem.rows[0]!.status).toBe("cancelled");

      const ticketItems = await listTicketItems(admin, orderId);
      expect(ticketItems[0]!.status).toBe("cancelled");
      expect(ticketItems[0]!.cancelled_by_staff_id).toBe(cashier.staffId);
      expect(ticketItems[0]!.cancellation_reason).toBe(
        `Remove ${state} item`,
      );

      const tickets = await listTickets(admin, orderId);
      expect(tickets[0]!.status).toBe("cancelled");
    }
  });

  it("rejects removing an item after kitchen work completed", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Completed removal"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Completed removal station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");
    const ticketItem = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, ticketItem.id);
    await readyItem(kitchen.client, ticketItem.id);
    await completeItem(kitchen.client, ticketItem.id);

    await expectPgError(
      removeOrderItem(cashier.client, orderItemId, "Too late"),
      "ORDER_MODIFICATION_NOT_ALLOWED",
    );

    const orderItem = await admin.query<{ status: string }>(
      "select status::text from public.order_items where id = $1",
      [orderItemId],
    );
    expect(orderItem.rows[0]!.status).toBe("accepted");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "completed",
    );
    expect((await listTickets(admin, orderId))[0]!.status).toBe("completed");
  });
});

describe("M4.2 multi-station routing", () => {
  it("routes one order item to two stations and keeps cancellation and regeneration coherent", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Two stations"),
    });
    const stationOne = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Station one"),
    });
    const stationTwo = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Station two"),
    });
    for (const stationId of [stationOne, stationTwo]) {
      await routeItem(admin, {
        organizationId: fixture.organizationId,
        branchId,
        stationId,
        menuItemId: menu.itemId,
      });
    }
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(2);
    expect(tickets.map((row) => row.station_id).sort()).toEqual(
      [stationOne, stationTwo].sort(),
    );

    const items = await listTicketItemsWithStations(admin, orderId);
    expect(items).toHaveLength(2);
    expect(new Set(items.map((row) => row.order_item_id))).toEqual(
      new Set([orderItemId]),
    );
    expect(new Set(items.map((row) => row.ticket_id)).size).toBe(2);

    const stationOneItem = items.find((row) => row.station_id === stationOne)!;
    const stationTwoItem = items.find((row) => row.station_id === stationTwo)!;

    await startItem(kitchen.client, stationOneItem.id);
    await readyItem(kitchen.client, stationOneItem.id);

    const afterIndependentProgress = await listTickets(admin, orderId);
    expect(
      afterIndependentProgress.find((row) => row.station_id === stationOne)
        ?.status,
    ).toBe("ready");
    expect(
      afterIndependentProgress.find((row) => row.station_id === stationTwo)
        ?.status,
    ).toBe("pending");

    await removeOrderItem(cashier.client, orderItemId, "Multi-station cancel");

    const afterCancellation = await listTickets(admin, orderId);
    expect(afterCancellation).toHaveLength(2);
    for (const row of afterCancellation) {
      expect(row.status).toBe("cancelled");
      expect(row.cancelled_by_staff_id).toBe(cashier.staffId);
      expect(row.cancellation_reason).toBe("Multi-station cancel");
    }
    const cancelledItems = await listTicketItems(admin, orderId);
    expect(cancelledItems).toHaveLength(2);
    for (const row of cancelledItems) {
      expect(row.status).toBe("cancelled");
      expect(row.cancelled_by_staff_id).toBe(cashier.staffId);
      expect(row.cancellation_reason).toBe("Multi-station cancel");
    }

    // New work after cancellation must create a new generation at both
    // stations without altering the cancelled history.
    const replacement = await addOrderItem(
      cashier.client,
      orderId,
      menu.itemId,
    );
    const replacementOrderItemId = newOrderItemIdForMenuItem(
      replacement,
      menu.itemId,
      orderItemId,
    );
    const afterReplacement = await listTickets(admin, orderId);
    expect(afterReplacement).toHaveLength(4);
    const historical = afterReplacement.filter(
      (row) => row.status === "cancelled",
    );
    const active = afterReplacement.filter((row) => row.status !== "cancelled");
    expect(historical).toHaveLength(2);
    expect(historical.every((row) => row.generation === 1)).toBe(true);
    expect(active).toHaveLength(2);
    expect(active.every((row) => row.generation === 2)).toBe(true);
    expect(active.map((row) => row.station_id).sort()).toEqual(
      [stationOne, stationTwo].sort(),
    );

    const replacementItems = await listTicketItems(admin, orderId);
    expect(replacementItems).toHaveLength(4);
    expect(
      replacementItems.filter(
        (row) => row.order_item_id === replacementOrderItemId,
      ),
    ).toHaveLength(2);
    expect(
      replacementItems
        .filter((row) => row.order_item_id === replacementOrderItemId)
        .every((row) => row.status === "pending"),
    ).toBe(true);
  });
});

describe("M4.2 cancellation attribution domains", () => {
  it("records the acting staff member and cancellation reason for staff cancellation", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Staff cancellation"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Staff cancellation station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    await cancelOrder(cashier.client, orderId, "Guest left");

    const ticket = (await listTickets(admin, orderId))[0]!;
    expect(ticket.cancelled_by_actor_type).toBe("staff");
    expect(ticket.cancelled_by_staff_id).toBe(cashier.staffId);
    expect(ticket.cancellation_reason).toBe("Guest left");

    const audit = await admin.query<{
      action: string;
      actor_type: string;
      actor_id: string | null;
      reason: string | null;
      metadata: Record<string, unknown>;
    }>(
      `select action, actor_type::text, actor_id, reason, metadata
         from public.audit_events
        where organization_id = $1
          and metadata ->> 'order_id' = $2
          and action in ('kitchen.ticket_status_changed',
                         'kitchen.ticket_item_status_changed')
        order by created_at, id`,
      [fixture.organizationId, orderId],
    );

    const ticketCancellation = audit.rows.find(
      (row) =>
        row.action === "kitchen.ticket_status_changed" &&
        row.metadata.to_status === "cancelled",
    );
    const itemCancellation = audit.rows.find(
      (row) =>
        row.action === "kitchen.ticket_item_status_changed" &&
        row.metadata.to_status === "cancelled",
    );
    for (const row of [ticketCancellation, itemCancellation]) {
      expect(row?.actor_type).toBe("staff");
      expect(row?.actor_id).toBe(cashier.staffId);
      expect(row?.reason).toBe("Guest left");
      expect(row?.metadata.cancelled_by_actor_type).toBe("staff");
      expect(row?.metadata.cancelled_by_staff_id).toBe(cashier.staffId);
    }
  });

  it("uses the system actor domain instead of the order submitter for privileged cancellation", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("System cancellation"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("System cancellation station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);

    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");

    await admin.query(
      `update public.order_items
          set status = 'cancelled',
              cancelled_at = now(),
              cancelled_by_staff_id = null,
              cancellation_reason = 'System cleanup'
        where id = $1`,
      [orderItemId],
    );

    const items = await listTicketItems(admin, orderId);
    expect(items[0]!.status).toBe("cancelled");
    expect(items[0]!.cancelled_by_actor_type).toBe("system");
    expect(items[0]!.cancelled_by_staff_id).toBeNull();
    expect(items[0]!.cancellation_reason).toBe("System cleanup");
    expect(items[0]!.cancelled_by_staff_id).not.toBe(cashier.staffId);

    const ticket = (await listTickets(admin, orderId))[0]!;
    expect(ticket.status).toBe("cancelled");
    expect(ticket.cancelled_by_actor_type).toBe("system");
    expect(ticket.cancelled_by_staff_id).toBeNull();
    expect(ticket.cancellation_reason).toBe("System cleanup");

    const audit = await admin.query<{
      action: string;
      actor_type: string;
      actor_id: string | null;
      reason: string | null;
      metadata: Record<string, unknown>;
    }>(
      `select action, actor_type::text, actor_id, reason, metadata
         from public.audit_events
        where organization_id = $1
          and metadata ->> 'order_id' = $2
          and action in ('kitchen.ticket_status_changed',
                         'kitchen.ticket_item_status_changed')
        order by created_at, id`,
      [fixture.organizationId, orderId],
    );

    const cancellationRows = audit.rows.filter(
      (row) => row.metadata.to_status === "cancelled",
    );
    expect(cancellationRows.length).toBeGreaterThanOrEqual(2);
    for (const row of cancellationRows) {
      expect(row.actor_type).toBe("system");
      expect(row.actor_id).toBeNull();
      expect(row.reason).toBe("System cleanup");
      expect(row.metadata.cancelled_by_actor_type).toBe("system");
      expect(row.metadata.cancelled_by_staff_id).toBeNull();
    }
  });
});

describe("M4.2 routing issue visibility", () => {
  it("reports inactive item-level routes and enforces branch authorization", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const item = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Routing issue item"),
    });
    const inactiveItemStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("Inactive item station"),
      status: "inactive",
    });
    const activeCategoryStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("Active category station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      stationId: inactiveItemStation,
      menuItemId: item.itemId,
    });
    await routeCategory(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      stationId: activeCategoryStation,
      menuCategoryId: item.categoryId,
    });

    const otherBranchItem = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Other branch routing issue"),
    });
    const otherBranchStation = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      name: uniqueName("Other branch inactive station"),
      status: "inactive",
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      stationId: otherBranchStation,
      menuItemId: otherBranchItem.itemId,
    });

    const owner = await createClient();
    track(owner);
    await authenticateAs(owner, fixture.ownerAuthUserId);

    const response = await listRoutingIssues(owner, branchA!);
    expect(response.branchId).toBe(branchA);
    const itemIssue = response.issues.find(
      (issue) =>
        issue.issueType === "inactive_item_route" &&
        issue.menuItemId === item.itemId,
    );
    expect(itemIssue).toMatchObject({
      issueType: "inactive_item_route",
      branchId: branchA,
      menuItemId: item.itemId,
      menuCategoryId: item.categoryId,
      stationId: inactiveItemStation,
      stationStatus: "inactive",
      categoryRouteActive: true,
    });
    expect(
      response.issues.some(
        (issue) =>
          issue.stationId === otherBranchStation ||
          issue.menuItemId === otherBranchItem.itemId,
      ),
    ).toBe(false);

    const cashier = await createCashier(admin, fixture, branchA!);
    await expectPgError(
      listRoutingIssues(cashier.client, branchA!),
      "PERMISSION_DENIED",
    );

    const kitchen = await createKitchenStaff(admin, fixture, [branchA!]);
    await expectPgError(
      listRoutingIssues(kitchen.client, branchA!),
      "PERMISSION_DENIED",
    );

    const otherOrg = await createOrgFixture(admin, { branchCount: 1 });
    const otherOwner = await createClient();
    track(otherOwner);
    await authenticateAs(otherOwner, otherOrg.ownerAuthUserId);
    await expectPgError(
      listRoutingIssues(otherOwner, branchA!),
      "BRANCH_NOT_FOUND",
    );
  });
});

describe("M4.2 final order-status removal policy", () => {
  const setupRemovalOrder = async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Post-accept removal"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Post-accept removal station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);
    const manager = await createManager(admin, fixture, [branchId]);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");

    return {
      admin,
      fixture,
      branchId,
      menu,
      station,
      cashier,
      kitchen,
      manager,
      orderId,
      orderItemId,
    };
  };

  it("allows removal when the order is preparing and the kitchen item is still pending", async () => {
    const { admin, cashier, manager, orderId, orderItemId } =
      await setupRemovalOrder();
    await transition(manager.client, orderId, "preparing");

    await removeOrderItem(cashier.client, orderItemId, "Remove pending item");

    const order = await admin.query<{ status: string; subtotal_minor: string }>(
      "select status::text, subtotal_minor from public.orders where id = $1",
      [orderId],
    );
    expect(order.rows[0]!.status).toBe("preparing");
    expect(Number(order.rows[0]!.subtotal_minor)).toBe(0);
    expect((await listTickets(admin, orderId))[0]!.status).toBe("cancelled");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "cancelled",
    );
  });

  it("allows removal when the order is preparing and the kitchen item is preparing", async () => {
    const { admin, cashier, kitchen, manager, menu, orderId, orderItemId } =
      await setupRemovalOrder();
    await transition(manager.client, orderId, "preparing");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, item.id);

    await removeOrderItem(cashier.client, orderItemId, "Remove preparing item");

    const order = await admin.query<{ status: string }>(
      "select status::text from public.orders where id = $1",
      [orderId],
    );
    expect(order.rows[0]!.status).toBe("preparing");
    expect((await listTickets(admin, orderId))[0]!.status).toBe("cancelled");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "cancelled",
    );
  });

  it("allows removal when the order and kitchen item are ready", async () => {
    const { admin, cashier, kitchen, manager, menu, orderId, orderItemId } =
      await setupRemovalOrder();
    await transition(manager.client, orderId, "preparing");
    await transition(manager.client, orderId, "ready");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, item.id);
    await readyItem(kitchen.client, item.id);

    await removeOrderItem(cashier.client, orderItemId, "Remove ready item");

    const order = await admin.query<{ status: string }>(
      "select status::text from public.orders where id = $1",
      [orderId],
    );
    expect(order.rows[0]!.status).toBe("ready");
    expect((await listTickets(admin, orderId))[0]!.status).toBe("cancelled");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "cancelled",
    );
  });

  it("rejects removal when the matching kitchen item is completed", async () => {
    const { admin, cashier, kitchen, manager, menu, orderId, orderItemId } =
      await setupRemovalOrder();
    await transition(manager.client, orderId, "preparing");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, item.id);
    await readyItem(kitchen.client, item.id);
    await completeItem(kitchen.client, item.id);

    await expectPgError(
      removeOrderItem(cashier.client, orderItemId, "Remove completed item"),
      "ORDER_MODIFICATION_NOT_ALLOWED",
    );

    const orderItem = await admin.query<{ status: string }>(
      "select status::text from public.order_items where id = $1",
      [orderItemId],
    );
    expect(orderItem.rows[0]!.status).toBe("preparing");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "completed",
    );
    expect((await listTickets(admin, orderId))[0]!.status).toBe("completed");
  });

  it("rejects multi-station removal atomically when one station is completed", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Multi station removal"),
    });
    const stationOne = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Multi removal one"),
    });
    const stationTwo = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Multi removal two"),
    });
    for (const stationId of [stationOne, stationTwo]) {
      await routeItem(admin, {
        organizationId: fixture.organizationId,
        branchId,
        stationId,
        menuItemId: menu.itemId,
      });
    }
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");

    const items = await listTicketItemsWithStations(admin, orderId);
    const stationOneItem = items.find((row) => row.station_id === stationOne)!;
    const stationTwoItem = items.find((row) => row.station_id === stationTwo)!;
    await startItem(kitchen.client, stationOneItem.id);
    await readyItem(kitchen.client, stationOneItem.id);
    await completeItem(kitchen.client, stationOneItem.id);
    await startItem(kitchen.client, stationTwoItem.id);
    await readyItem(kitchen.client, stationTwoItem.id);

    await expectPgError(
      removeOrderItem(cashier.client, orderItemId, "Multi station removal"),
      "ORDER_MODIFICATION_NOT_ALLOWED",
    );

    const after = await listTicketItemsWithStations(admin, orderId);
    expect(
      after.find((row) => row.station_id === stationOne)?.status,
    ).toBe("completed");
    expect(after.find((row) => row.station_id === stationTwo)?.status).toBe(
      "ready",
    );
    expect(
      (
        await admin.query<{ status: string }>(
          "select status::text from public.order_items where id = $1",
          [orderItemId],
        )
      ).rows[0]!.status,
    ).toBe("accepted");
  });

  it("rejects removal from a terminal served order", async () => {
    const { admin, cashier, manager, orderId, orderItemId } =
      await setupRemovalOrder();
    await transition(manager.client, orderId, "preparing");
    await transition(manager.client, orderId, "ready");
    await transition(cashier.client, orderId, "served");

    await expectPgError(
      removeOrderItem(cashier.client, orderItemId, "Terminal removal"),
      "ORDER_MODIFICATION_NOT_ALLOWED",
    );

    const orderItem = await admin.query<{ status: string }>(
      "select status::text from public.order_items where id = $1",
      [orderItemId],
    );
    expect(orderItem.rows[0]!.status).toBe("served");
    expect((await listTickets(admin, orderId))[0]!.status).toBe("pending");
  });
});

describe("M4.2 final direct item-write invariants", () => {
  it("recalculates the parent ticket after a direct item-status update", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Direct item write"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Direct item write station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);

    await admin.query(
      "update public.kitchen_ticket_items set status = 'preparing' where id = $1",
      [item.id],
    );

    expect((await listTickets(admin, orderId))[0]!.status).toBe("preparing");
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "preparing",
    );
  });

  it("rejects inserting an active item into a cancelled ticket", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Cancelled ticket insert"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Cancelled insert station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const oldOrderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");
    const oldTicket = (await listTickets(admin, orderId))[0]!;
    await removeOrderItem(cashier.client, oldOrderItemId, "Cancel old work");

    const added = await addOrderItem(cashier.client, orderId, menu.itemId);
    const newOrderItemId = newOrderItemIdForMenuItem(
      added,
      menu.itemId,
      oldOrderItemId,
    );

    await expectPgError(
      admin.query(
        `insert into public.kitchen_ticket_items
           (organization_id, branch_id, ticket_id, order_id, order_item_id)
         values ($1, $2, $3, $4, $5)`,
        [
          fixture.organizationId,
          branchId,
          oldTicket.id,
          orderId,
          newOrderItemId,
        ],
      ),
      "KITCHEN_TICKET_CANCELLED",
    );

    const oldItems = await admin.query<{ count: string }>(
      "select count(*)::text from public.kitchen_ticket_items where ticket_id = $1",
      [oldTicket.id],
    );
    expect(oldItems.rows[0]!.count).toBe("1");
  });
});

describe("M4.2 final cancellation attribution immutability", () => {
  it("rejects changing staff cancellation attribution or reason", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Immutable staff cancel"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Immutable staff cancel station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    await cancelOrder(cashier.client, orderId, "Staff cancellation");
    const ticket = (await listTickets(admin, orderId))[0]!;
    const item = (await listTicketItems(admin, orderId))[0]!;

    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set cancelled_by_staff_id = $2 where id = $1",
        [ticket.id, fixture.ownerStaffId],
      ),
      "KITCHEN_CANCELLATION_INVALID",
    );
    await expectPgError(
      admin.query(
        "update public.kitchen_ticket_items set cancellation_reason = 'changed' where id = $1",
        [item.id],
      ),
      "KITCHEN_CANCELLATION_INVALID",
    );

    expect((await listTickets(admin, orderId))[0]!.cancelled_by_staff_id).toBe(
      cashier.staffId,
    );
    expect(
      (await listTicketItems(admin, orderId))[0]!.cancellation_reason,
    ).toBe("Staff cancellation");
  });

  it("rejects changing system cancellation attribution or timestamp", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Immutable system cancel"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Immutable system cancel station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");
    await admin.query(
      `update public.order_items
          set status = 'cancelled',
              cancelled_at = now(),
              cancelled_by_staff_id = null,
              cancellation_reason = 'System cancellation'
        where id = $1`,
      [orderItemId],
    );
    const ticket = (await listTickets(admin, orderId))[0]!;
    const item = (await listTicketItems(admin, orderId))[0]!;
    expect(ticket.cancelled_by_actor_type).toBe("system");

    await expectPgError(
      admin.query(
        `update public.kitchen_tickets
            set cancelled_by_actor_type = 'staff',
                cancelled_by_staff_id = $2
          where id = $1`,
        [ticket.id, fixture.ownerStaffId],
      ),
      "KITCHEN_CANCELLATION_INVALID",
    );
    await expectPgError(
      admin.query(
        "update public.kitchen_ticket_items set cancelled_at = cancelled_at + interval '1 second' where id = $1",
        [item.id],
      ),
      "KITCHEN_CANCELLATION_INVALID",
    );

    const ticketAfter = (await listTickets(admin, orderId))[0]!;
    expect(ticketAfter.cancelled_by_actor_type).toBe("system");
    expect(ticketAfter.cancelled_by_staff_id).toBeNull();
    expect((await listTicketItems(admin, orderId))[0]!.status).toBe(
      "cancelled",
    );
  });
});

describe("M4.2 final concurrency and empty-ticket coverage", () => {
  it("creates only one active generation when two sessions add work concurrently after cancellation", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Concurrent regeneration"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Concurrent regeneration station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashierOne = await createCashier(admin, fixture, branchId);
    const cashierTwo = await createCashier(admin, fixture, branchId);
    const order = await createOrder(cashierOne.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const oldOrderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashierOne.client, orderId, "accepted");
    await removeOrderItem(cashierOne.client, oldOrderItemId, "Cancel old work");

    await Promise.all([
      addOrderItem(cashierOne.client, orderId, menu.itemId),
      addOrderItem(cashierTwo.client, orderId, menu.itemId),
    ]);
    const newOrderItems = await admin.query<{ id: string }>(
      `select id
         from public.order_items
        where order_id = $1
          and id <> $2
          and status <> 'cancelled'
        order by created_at, id`,
      [orderId, oldOrderItemId],
    );
    expect(newOrderItems.rows).toHaveLength(2);
    const newOrderItemIds = new Set(newOrderItems.rows.map((row) => row.id));

    const tickets = await listTickets(admin, orderId);
    expect(tickets).toHaveLength(2);
    expect(tickets.filter((row) => row.status !== "cancelled")).toHaveLength(
      1,
    );
    const activeTicket = tickets.find((row) => row.status !== "cancelled")!;
    expect(activeTicket.generation).toBe(2);
    expect(tickets.find((row) => row.generation === 1)?.status).toBe(
      "cancelled",
    );

    const items = await listTicketItems(admin, orderId);
    const newItems = items.filter((row) =>
      newOrderItemIds.has(row.order_item_id),
    );
    expect(newItems).toHaveLength(2);
    expect(newItems.every((row) => row.ticket_id === activeTicket.id)).toBe(
      true,
    );
    expect(newItems.every((row) => row.status === "pending")).toBe(true);
  });

  it("rejects invalid empty-ticket aggregates and allows attributed empty cancellation", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Empty ticket"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Empty ticket station"),
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    await transition(cashier.client, orderId, "accepted");
    const ticket = await admin.query<{ id: string }>(
      `insert into public.kitchen_tickets
         (organization_id, branch_id, order_id, station_id, status)
       values ($1, $2, $3, $4, 'pending')
       returning id`,
      [fixture.organizationId, branchId, orderId, station],
    );

    await expectPgError(
      admin.query(
        "update public.kitchen_tickets set status = 'ready' where id = $1",
        [ticket.rows[0]!.id],
      ),
      "KITCHEN_TICKET_INCONSISTENT",
    );
    expect(
      (
        await admin.query<{ status: string }>(
          "select status::text from public.kitchen_tickets where id = $1",
          [ticket.rows[0]!.id],
        )
      ).rows[0]!.status,
    ).toBe("pending");

    await admin.query(
      `update public.kitchen_tickets
          set status = 'cancelled',
              cancelled_at = now(),
              cancelled_by_actor_type = 'staff',
              cancelled_by_staff_id = $2,
              cancellation_reason = 'Empty ticket cancelled'
        where id = $1`,
      [ticket.rows[0]!.id, cashier.staffId],
    );
    expect(
      (
        await admin.query<{ status: string }>(
          "select status::text from public.kitchen_tickets where id = $1",
          [ticket.rows[0]!.id],
        )
      ).rows[0]!.status,
    ).toBe("cancelled");
  });

  it("serializes kitchen completion against item removal without silently removing completed work", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Completion removal race"),
    });
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Completion removal race station"),
    });
    await routeItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      stationId: station,
      menuItemId: menu.itemId,
    });
    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const cashier = await createCashier(admin, fixture, branchId);
    const kitchen = await createKitchenStaff(admin, fixture, [branchId]);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = order.orderId as string;
    const orderItemId = orderItemIdForMenuItem(order, menu.itemId);
    await transition(cashier.client, orderId, "accepted");
    const item = await ticketItemForMenuItem(admin, orderId, menu.itemId);
    await startItem(kitchen.client, item.id);
    await readyItem(kitchen.client, item.id);

    const results = await Promise.allSettled([
      completeItem(kitchen.client, item.id),
      removeOrderItem(cashier.client, orderItemId, "Race removal"),
    ]);
    const fulfilled = results.filter((result) => result.status === "fulfilled");
    expect(fulfilled).toHaveLength(1);

    const orderItem = await admin.query<{ status: string }>(
      "select status::text from public.order_items where id = $1",
      [orderItemId],
    );
    const ticketItem = (await listTicketItems(admin, orderId))[0]!;
    const ticket = (await listTickets(admin, orderId))[0]!;

    if (ticketItem.status === "cancelled") {
      expect(orderItem.rows[0]!.status).toBe("cancelled");
      expect(ticket.status).toBe("cancelled");
    } else {
      expect(ticketItem.status).toBe("completed");
      expect(orderItem.rows[0]!.status).toBe("accepted");
      expect(ticket.status).toBe("completed");
      const removalError = results[1] as PromiseRejectedResult;
      expect(String(removalError.reason)).toContain(
        "ORDER_MODIFICATION_NOT_ALLOWED",
      );
    }
  });
});


