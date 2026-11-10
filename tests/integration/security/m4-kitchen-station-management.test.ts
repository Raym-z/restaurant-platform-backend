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

type Station = Record<string, unknown>;
type StationList = { branchId: string; stations: Station[] };

const createOwnerClient = async (
  fixture: Fixture,
): Promise<pg.Client> => {
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

const createSessionForBranch = async (
  admin: pg.Client,
  fixture: Fixture,
  branchId: string,
): Promise<string> => {
  const table = await createTable(admin, {
    organizationId: fixture.organizationId,
    branchId,
    label: uniqueName("M4.3 table"),
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

const createStation = async (
  client: pg.Client,
  branchId: string,
  name: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.create_kitchen_station($1, $2, $3) as result",
    [branchId, name, "Test station"],
  );
  return result.rows[0]!.result;
};

const updateStation = async (
  client: pg.Client,
  stationId: string,
  name: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.update_kitchen_station($1, $2, $3) as result",
    [stationId, name, "Updated station"],
  );
  return result.rows[0]!.result;
};

const deactivateStation = async (
  client: pg.Client,
  stationId: string,
  reason?: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.deactivate_kitchen_station($1, $2) as result",
    [stationId, reason ?? null],
  );
  return result.rows[0]!.result;
};

const reactivateStation = async (
  client: pg.Client,
  stationId: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.reactivate_kitchen_station($1) as result",
    [stationId],
  );
  return result.rows[0]!.result;
};

const listStations = async (
  client: pg.Client,
  branchId: string,
): Promise<StationList> => {
  const result = await client.query<{ result: StationList }>(
    "select public.list_kitchen_stations($1) as result",
    [branchId],
  );
  return result.rows[0]!.result;
};

const addCategoryRoute = async (
  client: pg.Client,
  stationId: string,
  menuCategoryId: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.add_kitchen_station_category_route($1, $2) as result",
    [stationId, menuCategoryId],
  );
  return result.rows[0]!.result;
};

const removeCategoryRoute = async (
  client: pg.Client,
  stationId: string,
  menuCategoryId: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.remove_kitchen_station_category_route($1, $2) as result",
    [stationId, menuCategoryId],
  );
  return result.rows[0]!.result;
};

const addItemRoute = async (
  client: pg.Client,
  stationId: string,
  menuItemId: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.add_kitchen_station_item_route($1, $2) as result",
    [stationId, menuItemId],
  );
  return result.rows[0]!.result;
};

const removeItemRoute = async (
  client: pg.Client,
  stationId: string,
  menuItemId: string,
): Promise<Station> => {
  const result = await client.query<{ result: Station }>(
    "select public.remove_kitchen_station_item_route($1, $2) as result",
    [stationId, menuItemId],
  );
  return result.rows[0]!.result;
};

const listTickets = async (
  client: pg.Client,
  branchId: string,
  stationId: string,
): Promise<{ tickets: Array<Record<string, unknown>> }> => {
  const result = await client.query<{
    result: { tickets: Array<Record<string, unknown>> };
  }>(
    "select public.list_kitchen_tickets($1, $2, null, 50, 0, null, null) as result",
    [branchId, stationId],
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

describe("M4.3 kitchen station management", () => {
  it("creates, lists, updates, and rejects duplicate station names", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 2 });
    const branchId = fixture.branchIds[0]!;
    const owner = await createOwnerClient(fixture);
    const manager = await createBranchStaff(admin, fixture, "manager", [
      branchId,
    ]);
    const kitchen = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchId,
    ]);
    const cashier = await createBranchStaff(admin, fixture, "cashier", [
      branchId,
    ]);

    const name = uniqueName("Hot line");
    const station = await createStation(owner, branchId, name);
    expect(station.stationId).toBeTruthy();
    expect(station.name).toBe(name);
    expect(station.status).toBe("active");
    expect(station.deactivatedAt).toBeNull();
    expect(station.categoryRoutes).toEqual([]);
    expect(station.itemRoutes).toEqual([]);

    const listed = await listStations(kitchen.client, branchId);
    expect(listed.stations.some((row) => row.stationId === station.stationId)).toBe(
      true,
    );

    await expectPgError(
      createStation(owner, branchId, `  ${name.toUpperCase()}  `),
      "RESOURCE_CONFLICT",
    );

    const renamed = await updateStation(owner, String(station.stationId), uniqueName("Cold line"));
    expect(renamed.name).not.toBe(name);

    await expectPgError(
      createStation(kitchen.client, branchId, uniqueName("Kitchen denied")),
      "PERMISSION_DENIED",
    );
    await expectPgError(
      createStation(cashier.client, branchId, uniqueName("Cashier denied")),
      "PERMISSION_DENIED",
    );

    // A branch-scoped Manager is authorized to configure the branch.
    const managerRenamed = await updateStation(
      manager.client,
      String(station.stationId),
      uniqueName("Manager rename"),
    );
    expect(managerRenamed.name).toContain("Manager rename");

    await expectPgError(
      updateStation(kitchen.client, String(station.stationId), uniqueName("Kitchen rename")),
      "PERMISSION_DENIED",
    );

    const otherOrg = await createOrgFixture(admin, { branchCount: 1 });
    const otherOwner = await createOwnerClient(otherOrg);
    await expectPgError(
      createStation(otherOwner, branchId, uniqueName("Cross org")),
      "BRANCH_NOT_FOUND",
    );

    const audit = await admin.query<{ action: string }>(
      `select action
         from public.audit_events
        where target_id = $1
        order by created_at`,
      [station.stationId],
    );
    expect(audit.rows.map((row) => row.action)).toContain(
      "kitchen.station_created",
    );
    expect(audit.rows.map((row) => row.action)).toContain(
      "kitchen.station_updated",
    );
  });

  it("manages category and item routes with audit records", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const owner = await createOwnerClient(fixture);
    const kitchen = await createBranchStaff(admin, fixture, "kitchen_staff", [
      branchId,
    ]);
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Route item"),
    });
    const station = await createStation(owner, branchId, uniqueName("Route station"));
    const stationId = String(station.stationId);

    const withCategory = await addCategoryRoute(
      owner,
      stationId,
      menu.categoryId,
    );
    expect(
      (withCategory.categoryRoutes as Array<Record<string, unknown>>).map(
        (route) => route.menuCategoryId,
      ),
    ).toContain(menu.categoryId);

    await expectPgError(
      addCategoryRoute(owner, stationId, menu.categoryId),
      "RESOURCE_CONFLICT",
    );

    const withItem = await addItemRoute(owner, stationId, menu.itemId);
    expect(
      (withItem.itemRoutes as Array<Record<string, unknown>>).map(
        (route) => route.menuItemId,
      ),
    ).toContain(menu.itemId);

    await expectPgError(
      addItemRoute(owner, stationId, menu.itemId),
      "RESOURCE_CONFLICT",
    );

    await expectPgError(
      addItemRoute(kitchen.client, stationId, menu.itemId),
      "PERMISSION_DENIED",
    );

    const withoutCategory = await removeCategoryRoute(
      owner,
      stationId,
      menu.categoryId,
    );
    expect(withoutCategory.categoryRoutes).toEqual([]);

    await expectPgError(
      removeCategoryRoute(owner, stationId, menu.categoryId),
      "RESOURCE_CONFLICT",
    );

    const withoutItem = await removeItemRoute(owner, stationId, menu.itemId);
    expect(withoutItem.itemRoutes).toEqual([]);

    const audit = await admin.query<{ action: string }>(
      `select action
         from public.audit_events
        where metadata ->> 'station_id' = $1
        order by created_at`,
      [stationId],
    );
    const actions = audit.rows.map((row) => row.action);
    expect(actions).toContain("kitchen.category_route_added");
    expect(actions).toContain("kitchen.category_route_removed");
    expect(actions).toContain("kitchen.item_route_added");
    expect(actions).toContain("kitchen.item_route_removed");
  });

  it("rejects routes to inactive stations but allows removal", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const owner = await createOwnerClient(fixture);
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Inactive route item"),
    });
    const station = await createStation(owner, branchId, uniqueName("Inactive route station"));
    const stationId = String(station.stationId);

    await addItemRoute(owner, stationId, menu.itemId);
    const deactivated = await deactivateStation(
      owner,
      stationId,
      "Equipment maintenance",
    );
    expect(deactivated.status).toBe("inactive");
    expect(deactivated.deactivatedAt).not.toBeNull();

    await expectPgError(
      addItemRoute(owner, stationId, menu.itemId),
      "KITCHEN_STATION_INACTIVE",
    );

    const removed = await removeItemRoute(owner, stationId, menu.itemId);
    expect(removed.itemRoutes).toEqual([]);
  });

  it("keeps existing tickets readable and completable after deactivation", async () => {
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
    const menu = await createMenuItem(admin, {
      organizationId: fixture.organizationId,
      name: uniqueName("Deactivation item"),
    });
    const station = await createStation(owner, branchId, uniqueName("Deactivation station"));
    const stationId = String(station.stationId);
    await addItemRoute(owner, stationId, menu.itemId);

    const sessionId = await createSessionForBranch(admin, fixture, branchId);
    const order = await createOrder(cashier.client, sessionId, [
      { menuItemId: menu.itemId, quantity: 1 },
    ]);
    const orderId = String(order.orderId);
    await transition(cashier.client, orderId, "accepted");

    const board = await listTickets(kitchen.client, branchId, stationId);
    expect(board.tickets).toHaveLength(1);
    const ticket = board.tickets[0]!;
    const item = (ticket.items as Array<Record<string, unknown>>)[0]!;
    expect(ticket.stationName).toBe(station.name);

    await startItem(kitchen.client, String(item.ticketItemId));

    const deactivated = await deactivateStation(
      owner,
      stationId,
      "End of shift",
    );
    expect(deactivated.status).toBe("inactive");

    const afterDeactivation = await listTickets(
      kitchen.client,
      branchId,
      stationId,
    );
    expect(afterDeactivation.tickets).toHaveLength(1);
    expect(afterDeactivation.tickets[0]!.status).toBe("preparing");

    await readyItem(kitchen.client, String(item.ticketItemId));
    await completeItem(kitchen.client, String(item.ticketItemId));

    // Completed work is excluded from the default active board; read it back by
    // ticket id instead of requesting unrestricted history.
    const completed = await getTicket(
      kitchen.client,
      String(ticket.ticketId),
    );
    expect(completed.status).toBe("completed");

    const reactivated = await reactivateStation(owner, stationId);
    expect(reactivated.status).toBe("active");
    expect(reactivated.deactivatedAt).toBeNull();
    expect(
      (reactivated.itemRoutes as Array<Record<string, unknown>>).map(
        (route) => route.menuItemId,
      ),
    ).toContain(menu.itemId);

    const audit = await admin.query<{ action: string }>(
      `select action
         from public.audit_events
        where target_id = $1
        order by created_at`,
      [stationId],
    );
    const actions = audit.rows.map((row) => row.action);
    expect(actions).toContain("kitchen.station_deactivated");
    expect(actions).toContain("kitchen.station_reactivated");
  });

  it("denies cashier and cross-organization station access", async () => {
    const admin = await createClient();
    track(admin);
    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const branchId = fixture.branchIds[0]!;
    const owner = await createOwnerClient(fixture);
    const cashier = await createBranchStaff(admin, fixture, "cashier", [
      branchId,
    ]);
    const station = await createStation(owner, branchId, uniqueName("Security station"));
    const stationId = String(station.stationId);

    await expectPgError(
      listStations(cashier.client, branchId),
      "PERMISSION_DENIED",
    );

    const otherOrg = await createOrgFixture(admin, { branchCount: 1 });
    const otherOwner = await createOwnerClient(otherOrg);

    await expectPgError(
      updateStation(otherOwner, stationId, uniqueName("Cross org update")),
      "KITCHEN_STATION_NOT_FOUND",
    );
    await expectPgError(
      deactivateStation(otherOwner, stationId),
      "KITCHEN_STATION_NOT_FOUND",
    );
    await expectPgError(
      listStations(otherOwner, branchId),
      "BRANCH_NOT_FOUND",
    );
  });
});
