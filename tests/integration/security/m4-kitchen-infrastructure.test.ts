import { randomUUID } from "node:crypto";

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

const createMenuItem = async (
  admin: pg.Client,
  options: { organizationId: string; name: string; basePriceMinor?: number },
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
     values ($1, $2, $3, $4, 'IDR')
     returning id`,
    [
      options.organizationId,
      category.rows[0]!.id,
      options.name,
      options.basePriceMinor ?? 10000,
    ],
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
    [options.organizationId, options.branchId, options.name, status, deactivatedAt],
  );
  return result.rows[0]!.id;
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
    [options.organizationId, options.branchId, options.tableId, options.staffId],
  );
  return result.rows[0]!.id;
};

const createOrder = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    sessionId: string;
    staffId: string;
  },
): Promise<string> => {
  const result = await admin.query<{ id: string }>(
    `insert into public.orders
       (organization_id, branch_id, dining_session_id, source, status,
        currency_code, subtotal_minor, submitted_by_staff_id)
     values ($1, $2, $3, 'staff', 'pending', 'IDR', 0, $4)
     returning id`,
    [options.organizationId, options.branchId, options.sessionId, options.staffId],
  );
  return result.rows[0]!.id;
};

const createOrderItem = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    orderId: string;
    menuItemId: string;
    quantity?: number;
  },
): Promise<string> => {
  const result = await admin.query<{ id: string }>(
    `insert into public.order_items
       (order_id, organization_id, branch_id, menu_item_id, item_name_snapshot,
        base_unit_price_minor, quantity, currency_code)
     values ($1, $2, $3, $4, 'Kitchen fixture item', 10000, $5, 'IDR')
     returning id`,
    [
      options.orderId,
      options.organizationId,
      options.branchId,
      options.menuItemId,
      options.quantity ?? 1,
    ],
  );
  return result.rows[0]!.id;
};

const createTicket = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    orderId: string;
    stationId: string;
    status?: "pending" | "cancelled";
    cancelledByStaffId?: string | null;
    cancellationReason?: string | null;
  },
): Promise<string> => {
  const status = options.status ?? "pending";
  const cancelled =
    status === "cancelled"
      ? {
          at: new Date().toISOString(),
          by: options.cancelledByStaffId ?? null,
          reason: options.cancellationReason ?? null,
        }
      : { at: null, by: null, reason: null };
  const result = await admin.query<{ id: string }>(
    `insert into public.kitchen_tickets
       (organization_id, branch_id, order_id, station_id, status,
        cancelled_at, cancelled_by_staff_id, cancellation_reason)
     values ($1, $2, $3, $4, $5::public.kitchen_ticket_status, $6, $7, $8)
     returning id`,
    [
      options.organizationId,
      options.branchId,
      options.orderId,
      options.stationId,
      status,
      cancelled.at,
      cancelled.by,
      cancelled.reason,
    ],
  );
  return result.rows[0]!.id;
};

const createTicketItem = async (
  admin: pg.Client,
  options: {
    organizationId: string;
    branchId: string;
    ticketId: string;
    orderId: string;
    orderItemId: string;
  },
): Promise<string> => {
  const result = await admin.query<{ id: string }>(
    `insert into public.kitchen_ticket_items
       (organization_id, branch_id, ticket_id, order_id, order_item_id)
     values ($1, $2, $3, $4, $5)
     returning id`,
    [
      options.organizationId,
      options.branchId,
      options.ticketId,
      options.orderId,
      options.orderItemId,
    ],
  );
  return result.rows[0]!.id;
};

const createOrderFixture = async (
  admin: pg.Client,
  fixture: Fixture,
  branchId: string,
  label: string,
  menuItemId: string,
) => {
  const table = await createTable(admin, {
    organizationId: fixture.organizationId,
    branchId,
    label,
  });
  const sessionId = await createDiningSession(admin, {
    organizationId: fixture.organizationId,
    branchId,
    tableId: table.tableId,
    staffId: fixture.ownerStaffId,
  });
  const orderId = await createOrder(admin, {
    organizationId: fixture.organizationId,
    branchId,
    sessionId,
    staffId: fixture.ownerStaffId,
  });
  const orderItemId = await createOrderItem(admin, {
    organizationId: fixture.organizationId,
    branchId,
    orderId,
    menuItemId,
  });
  return { tableId: table.tableId, sessionId, orderId, orderItemId };
};

const countRows = async (client: pg.Client, table: string): Promise<number> => {
  const result = await client.query<{ count: string }>(
    `select count(*)::text as count from public.${table}`,
  );
  return Number(result.rows[0]!.count);
};

const authenticateAnon = async (client: pg.Client): Promise<void> => {
  const anonId = "00000000-0000-0000-0000-000000000000";
  await client.query(
    `select set_config('request.jwt.claims', $1, false),
            set_config('request.jwt.claim.sub', $2, false),
            set_config('request.jwt.claim.role', 'anon', false)`,
    [
      JSON.stringify({ sub: anonId, role: "anon", aud: "authenticated" }),
      anonId,
    ],
  );
  await client.query("set role anon");
};

describe("M4.1 kitchen station schema", () => {
  it("creates branch-scoped stations with active and inactive state", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;

    const stationA = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("Hot Line"),
    });
    const stationB = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      name: uniqueName("Cold Line"),
    });
    const inactive = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("Legacy Station"),
      status: "inactive",
    });

    const rows = await admin.query<{
      id: string;
      status: string;
      deactivated_at: Date | null;
    }>(
      `select id, status::text, deactivated_at
         from public.kitchen_stations
        where id = any($1::uuid[])`,
      [[stationA, stationB, inactive]],
    );

    expect(rows.rows).toHaveLength(3);
    expect(rows.rows.find((row) => row.id === stationA)?.status).toBe("active");
    expect(rows.rows.find((row) => row.id === stationB)?.status).toBe("active");
    expect(rows.rows.find((row) => row.id === inactive)?.status).toBe("inactive");
    expect(rows.rows.find((row) => row.id === inactive)?.deactivated_at).not.toBeNull();
  });

  it("rejects duplicate station names within a branch but allows another branch", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const name = uniqueName("Grill");

    await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name,
    });

    await expectPgError(
      createStation(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA!,
        name: `  ${name.toUpperCase()}  `,
      }),
      "duplicate key value violates unique constraint",
    );

    await expect(
      createStation(admin, {
        organizationId: fixture.organizationId,
        branchId: branchB!,
        name,
      }),
    ).resolves.toEqual(expect.any(String));
  });

  it("rejects invalid station tenant and status combinations", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const other = await createOrgFixture(admin, { branchCount: 1 });

    await expectPgError(
      createStation(admin, {
        organizationId: other.organizationId,
        branchId: fixture.branchIds[0]!,
        name: uniqueName("Cross Tenant"),
      }),
      "violates foreign key constraint",
    );

    await expectPgError(
      createStation(admin, {
        organizationId: fixture.organizationId,
        branchId: fixture.branchIds[0]!,
        name: "   ",
      }),
      "kitchen_stations_name_check",
    );

    await expectPgError(
      createStation(admin, {
        organizationId: fixture.organizationId,
        branchId: fixture.branchIds[0]!,
        name: uniqueName("Missing Timestamp"),
        status: "inactive",
        deactivatedAt: null,
      }),
      "kitchen_stations_status_timestamp_check",
    );

    await expectPgError(
      createStation(admin, {
        organizationId: fixture.organizationId,
        branchId: fixture.branchIds[0]!,
        name: uniqueName("Active With Timestamp"),
        status: "active",
        deactivatedAt: new Date().toISOString(),
      }),
      "kitchen_stations_status_timestamp_check",
    );
  });
});

describe("M4.1 menu routing", () => {
  it("stores valid category and item routes and rejects duplicates", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const stationA = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("Routing Station"),
    });
    const stationB = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      name: uniqueName("Routing Station B"),
    });
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Routing Menu"),
    });

    await expect(
      admin.query(
        `insert into public.kitchen_station_menu_categories
           (organization_id, branch_id, station_id, menu_category_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchA, stationA, menu.categoryId],
      ),
    ).resolves.toBeDefined();

    await expect(
      admin.query(
        `insert into public.kitchen_station_menu_items
           (organization_id, branch_id, station_id, menu_item_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchA, stationA, menu.itemId],
      ),
    ).resolves.toBeDefined();

    await expectPgError(
      admin.query(
        `insert into public.kitchen_station_menu_categories
           (organization_id, branch_id, station_id, menu_category_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchA, stationA, menu.categoryId],
      ),
      "duplicate key value violates unique constraint",
    );

    await expectPgError(
      admin.query(
        `insert into public.kitchen_station_menu_items
           (organization_id, branch_id, station_id, menu_item_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchA, stationA, menu.itemId],
      ),
      "duplicate key value violates unique constraint",
    );

    // The same organization-level category may be routed to a station in
    // another branch; the station's branch is the routing scope.
    await expect(
      admin.query(
        `insert into public.kitchen_station_menu_categories
           (organization_id, branch_id, station_id, menu_category_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchB, stationB, menu.categoryId],
      ),
    ).resolves.toBeDefined();
  });

  it("rejects cross-branch station routing and cross-organization menu targets", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const other = await createOrgFixture(admin, { branchCount: 1 });
    const stationA = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("Scope Station"),
    });
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Scope Menu"),
    });
    const otherMenu = await createMenuItem(admin, {
      organizationId: other.organizationId,
      name: uniqueName("Other Menu"),
    });

    await expectPgError(
      admin.query(
        `insert into public.kitchen_station_menu_items
           (organization_id, branch_id, station_id, menu_item_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchB, stationA, menu.itemId],
      ),
      "kitchen_station_menu_items_station_fkey",
    );

    await expectPgError(
      admin.query(
        `insert into public.kitchen_station_menu_items
           (organization_id, branch_id, station_id, menu_item_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchA, stationA, otherMenu.itemId],
      ),
      "kitchen_station_menu_items_item_organization_fkey",
    );

    await expectPgError(
      admin.query(
        `insert into public.kitchen_station_menu_categories
           (organization_id, branch_id, station_id, menu_category_id)
         values ($1, $2, $3, $4)`,
        [fixture.organizationId, branchA, stationA, otherMenu.categoryId],
      ),
      "kitchen_station_menu_categories_category_organization_fkey",
    );
  });
});

describe("M4.1 kitchen tickets", () => {
  it("creates one ticket per order and station, with ticket items", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Ticket Menu"),
    });
    const order = await createOrderFixture(
      admin,
      fixture,
      branchId,
      uniqueName("Ticket Table"),
      menu.itemId,
    );
    const stationA = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Ticket Station A"),
    });
    const stationB = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Ticket Station B"),
    });

    const ticketA = await createTicket(admin, {
      organizationId: fixture.organizationId,
      branchId,
      orderId: order.orderId,
      stationId: stationA,
    });
    const ticketB = await createTicket(admin, {
      organizationId: fixture.organizationId,
      branchId,
      orderId: order.orderId,
      stationId: stationB,
    });
    const ticketItem = await createTicketItem(admin, {
      organizationId: fixture.organizationId,
      branchId,
      ticketId: ticketA,
      orderId: order.orderId,
      orderItemId: order.orderItemId,
    });

    const tickets = await admin.query<{ id: string; status: string }>(
      `select id, status::text from public.kitchen_tickets where order_id = $1 order by id`,
      [order.orderId],
    );
    expect(tickets.rows).toHaveLength(2);
    expect(tickets.rows.map((row) => row.id).sort()).toEqual(
      [ticketA, ticketB].sort(),
    );
    expect(tickets.rows[0]!.status).toBe("pending");

    const items = await admin.query<{ id: string }>(
      `select id from public.kitchen_ticket_items where ticket_id = $1`,
      [ticketA],
    );
    expect(items.rows.map((row) => row.id)).toEqual([ticketItem]);
  });

  it("rejects duplicate tickets, duplicate ticket items, and cross-scope links", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const branchA = fixture.branchIds[0]!;
    const branchB = fixture.branchIds[1]!;
    const other = await createOrgFixture(admin, { branchCount: 1 });
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Ticket Integrity Menu"),
    });
    const branchAOrder = await createOrderFixture(
      admin,
      fixture,
      branchA,
      uniqueName("Integrity Table A"),
      menu.itemId,
    );
    const branchBOrder = await createOrderFixture(
      admin,
      fixture,
      branchB,
      uniqueName("Integrity Table B"),
      menu.itemId,
    );
    const otherMenu = await createMenuItem(admin, {
      organizationId: other.organizationId,
      name: uniqueName("Other Integrity Menu"),
    });
    const otherOrder = await createOrderFixture(
      admin,
      other,
      other.branchIds[0]!,
      uniqueName("Other Integrity Table"),
      otherMenu.itemId,
    );

    const stationA = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA,
      name: uniqueName("Integrity Station A"),
    });
    const stationB = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB,
      name: uniqueName("Integrity Station B"),
    });
    const ticketA = await createTicket(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA,
      orderId: branchAOrder.orderId,
      stationId: stationA,
    });
    await createTicketItem(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA,
      ticketId: ticketA,
      orderId: branchAOrder.orderId,
      orderItemId: branchAOrder.orderItemId,
    });

    await expectPgError(
      createTicket(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA,
        orderId: branchAOrder.orderId,
        stationId: stationA,
      }),
      "duplicate key value violates unique constraint",
    );

    await expectPgError(
      createTicketItem(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA,
        ticketId: ticketA,
        orderId: branchAOrder.orderId,
        orderItemId: branchAOrder.orderItemId,
      }),
      "duplicate key value violates unique constraint",
    );

    await expectPgError(
      createTicket(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA,
        orderId: branchAOrder.orderId,
        stationId: stationB,
      }),
      "kitchen_tickets_station_fkey",
    );

    await expectPgError(
      createTicket(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA,
        orderId: otherOrder.orderId,
        stationId: stationA,
      }),
      "kitchen_tickets_order_fkey",
    );

    await expectPgError(
      createTicketItem(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA,
        ticketId: ticketA,
        orderId: branchAOrder.orderId,
        orderItemId: branchBOrder.orderItemId,
      }),
      "kitchen_ticket_items_order_item_fkey",
    );

    await expectPgError(
      createTicketItem(admin, {
        organizationId: fixture.organizationId,
        branchId: branchA,
        ticketId: ticketA,
        orderId: branchAOrder.orderId,
        orderItemId: otherOrder.orderItemId,
      }),
      "kitchen_ticket_items_order_item_fkey",
    );
  });

  it("requires cancellation attribution on cancelled tickets", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Cancel Menu"),
    });
    const order = await createOrderFixture(
      admin,
      fixture,
      branchId,
      uniqueName("Cancel Table"),
      menu.itemId,
    );
    const station = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId,
      name: uniqueName("Cancel Station"),
    });

    await expectPgError(
      createTicket(admin, {
        organizationId: fixture.organizationId,
        branchId,
        orderId: order.orderId,
        stationId: station,
        status: "cancelled",
        cancelledByStaffId: null,
        cancellationReason: null,
      }),
      "kitchen_tickets_cancellation_check",
    );

    await expectPgError(
      createTicket(admin, {
        organizationId: fixture.organizationId,
        branchId,
        orderId: order.orderId,
        stationId: station,
        status: "cancelled",
        cancelledByStaffId: fixture.ownerStaffId,
        cancellationReason: "   ",
      }),
      "kitchen_tickets_cancellation_check",
    );

    await expect(
      createTicket(admin, {
        organizationId: fixture.organizationId,
        branchId,
        orderId: order.orderId,
        stationId: station,
        status: "cancelled",
        cancelledByStaffId: fixture.ownerStaffId,
        cancellationReason: "Station closed",
      }),
    ).resolves.toEqual(expect.any(String));
  });
});

describe("M4.1 kitchen RLS and M2/M3 regression", () => {
  it("limits kitchen data to authorized branch roles and blocks client writes", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const [branchA, branchB] = fixture.branchIds;
    const other = await createOrgFixture(admin, { branchCount: 1 });
    const otherBranch = other.branchIds[0]!;

    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("RLS Menu"),
    });
    const otherMenu = await createMenuItem(admin, {
      organizationId: other.organizationId,
      name: uniqueName("RLS Other Menu"),
    });
    const orderA = await createOrderFixture(
      admin,
      fixture,
      branchA!,
      uniqueName("RLS Table A"),
      menu.itemId,
    );
    const orderB = await createOrderFixture(
      admin,
      fixture,
      branchB!,
      uniqueName("RLS Table B"),
      menu.itemId,
    );
    const orderOther = await createOrderFixture(
      admin,
      other,
      otherBranch,
      uniqueName("RLS Other Table"),
      otherMenu.itemId,
    );

    const stationA = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      name: uniqueName("RLS Station A"),
    });
    const stationB = await createStation(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      name: uniqueName("RLS Station B"),
    });
    const stationOther = await createStation(admin, {
      organizationId: other.organizationId,
      branchId: otherBranch,
      name: uniqueName("RLS Other Station"),
    });

    await admin.query(
      `insert into public.kitchen_station_menu_items
         (organization_id, branch_id, station_id, menu_item_id)
       values ($1, $2, $3, $4), ($5, $6, $7, $8), ($9, $10, $11, $12)`,
      [
        fixture.organizationId, branchA, stationA, menu.itemId,
        fixture.organizationId, branchB, stationB, menu.itemId,
        other.organizationId, otherBranch, stationOther, otherMenu.itemId,
      ],
    );
    await admin.query(
      `insert into public.kitchen_station_menu_categories
         (organization_id, branch_id, station_id, menu_category_id)
       values ($1, $2, $3, $4), ($5, $6, $7, $8), ($9, $10, $11, $12)`,
      [
        fixture.organizationId, branchA, stationA, menu.categoryId,
        fixture.organizationId, branchB, stationB, menu.categoryId,
        other.organizationId, otherBranch, stationOther, otherMenu.categoryId,
      ],
    );

    const ticketA = await createTicket(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      orderId: orderA.orderId,
      stationId: stationA,
    });
    const ticketB = await createTicket(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      orderId: orderB.orderId,
      stationId: stationB,
    });
    const ticketOther = await createTicket(admin, {
      organizationId: other.organizationId,
      branchId: otherBranch,
      orderId: orderOther.orderId,
      stationId: stationOther,
    });

    await createTicketItem(admin, {
      organizationId: fixture.organizationId,
      branchId: branchA!,
      ticketId: ticketA,
      orderId: orderA.orderId,
      orderItemId: orderA.orderItemId,
    });
    await createTicketItem(admin, {
      organizationId: fixture.organizationId,
      branchId: branchB!,
      ticketId: ticketB,
      orderId: orderB.orderId,
      orderItemId: orderB.orderItemId,
    });
    await createTicketItem(admin, {
      organizationId: other.organizationId,
      branchId: otherBranch,
      ticketId: ticketOther,
      orderId: orderOther.orderId,
      orderItemId: orderOther.orderItemId,
    });

    const managerA = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "manager",
      scope: "branch",
      branchIds: [branchA!],
    });
    const kitchenA = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "kitchen_staff",
      scope: "branch",
      branchIds: [branchA!],
    });
    const cashierA = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "cashier",
      scope: "branch",
      branchIds: [branchA!],
    });
    const kitchenB = await addStaff(admin, {
      organizationId: fixture.organizationId,
      role: "kitchen_staff",
      scope: "branch",
      branchIds: [branchB!],
    });

    const ownerClient = await createClient();
    const managerClient = await createClient();
    const kitchenClient = await createClient();
    const cashierClient = await createClient();
    const kitchenBClient = await createClient();
    const otherOwnerClient = await createClient();
    const anonClient = await createClient();
    track(
      ownerClient,
      managerClient,
      kitchenClient,
      cashierClient,
      kitchenBClient,
      otherOwnerClient,
      anonClient,
    );

    await authenticateAs(ownerClient, fixture.ownerAuthUserId);
    await authenticateAs(managerClient, managerA.authUserId);
    await authenticateAs(kitchenClient, kitchenA.authUserId);
    await authenticateAs(cashierClient, cashierA.authUserId);
    await authenticateAs(kitchenBClient, kitchenB.authUserId);
    await authenticateAs(otherOwnerClient, other.ownerAuthUserId);
    await authenticateAnon(anonClient);

    expect(await countRows(ownerClient, "kitchen_stations")).toBe(2);
    expect(await countRows(managerClient, "kitchen_stations")).toBe(1);
    expect(await countRows(kitchenClient, "kitchen_stations")).toBe(1);
    expect(await countRows(cashierClient, "kitchen_stations")).toBe(0);
    expect(await countRows(kitchenBClient, "kitchen_stations")).toBe(1);
    expect(await countRows(otherOwnerClient, "kitchen_stations")).toBe(1);

    expect(await countRows(ownerClient, "kitchen_station_menu_items")).toBe(2);
    expect(await countRows(managerClient, "kitchen_station_menu_items")).toBe(1);
    expect(await countRows(kitchenClient, "kitchen_station_menu_items")).toBe(1);
    expect(await countRows(cashierClient, "kitchen_station_menu_items")).toBe(0);

    expect(await countRows(ownerClient, "kitchen_station_menu_categories")).toBe(2);
    expect(await countRows(managerClient, "kitchen_station_menu_categories")).toBe(1);
    expect(await countRows(kitchenClient, "kitchen_station_menu_categories")).toBe(1);
    expect(await countRows(cashierClient, "kitchen_station_menu_categories")).toBe(0);
    expect(await countRows(kitchenBClient, "kitchen_station_menu_categories")).toBe(1);
    expect(await countRows(otherOwnerClient, "kitchen_station_menu_categories")).toBe(1);

    expect(await countRows(ownerClient, "kitchen_tickets")).toBe(2);
    expect(await countRows(managerClient, "kitchen_tickets")).toBe(1);
    expect(await countRows(kitchenClient, "kitchen_tickets")).toBe(1);
    expect(await countRows(cashierClient, "kitchen_tickets")).toBe(0);
    expect(await countRows(kitchenBClient, "kitchen_tickets")).toBe(1);
    expect(await countRows(otherOwnerClient, "kitchen_tickets")).toBe(1);

    expect(await countRows(ownerClient, "kitchen_ticket_items")).toBe(2);
    expect(await countRows(managerClient, "kitchen_ticket_items")).toBe(1);
    expect(await countRows(kitchenClient, "kitchen_ticket_items")).toBe(1);
    expect(await countRows(cashierClient, "kitchen_ticket_items")).toBe(0);
    expect(await countRows(kitchenBClient, "kitchen_ticket_items")).toBe(1);
    expect(await countRows(otherOwnerClient, "kitchen_ticket_items")).toBe(1);

    // Kitchen staff must not gain unrelated staff or subscription visibility.
    expect(await countRows(kitchenClient, "staff_profiles")).toBe(1);
    expect(await countRows(kitchenClient, "subscriptions")).toBe(0);

    // Existing M3 order RLS remains branch-scoped.
    expect(await countRows(managerClient, "orders")).toBe(1);
    expect(await countRows(kitchenClient, "orders")).toBe(1);
    expect(await countRows(cashierClient, "orders")).toBe(1);
    expect(await countRows(kitchenBClient, "orders")).toBe(1);
    expect(await countRows(otherOwnerClient, "orders")).toBe(1);

    await expectPgError(
      anonClient.query("select count(*) from public.kitchen_stations"),
      "permission denied",
    );

    await expectPgError(
      managerClient.query(
        `insert into public.kitchen_stations (organization_id, branch_id, name)
         values ($1, $2, $3)`,
        [fixture.organizationId, branchA, uniqueName("Forbidden Station")],
      ),
      "permission denied",
    );

    await expectPgError(
      managerClient.query(
        "update public.kitchen_tickets set status = 'ready' where id = $1",
        [ticketA],
      ),
      "permission denied",
    );

    await expectPgError(
      managerClient.query("delete from public.kitchen_ticket_items where ticket_id = $1", [
        ticketA,
      ]),
      "permission denied",
    );

    // M3 order lifecycle must still work after the M4.1 schema additions.
    const transition = await managerClient.query<{
      result: { status: string };
    }>(
      "select public.transition_order_status($1, 'accepted'::public.order_status, null) as result",
      [orderA.orderId],
    );
    expect(transition.rows[0]!.result.status).toBe("accepted");

    const itemStatus = await admin.query<{ status: string }>(
      "select status::text from public.order_items where id = $1",
      [orderA.orderItemId],
    );
    expect(itemStatus.rows[0]!.status).toBe("accepted");
  });
});
