import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";

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

describe("M4.3 kitchen realtime publication configuration", () => {
  it("publishes exactly the approved kitchen tables", async () => {
    const client = await createClient();
    track(client);

    const result = await client.query<{ tablename: string }>(
      `select tablename
         from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename like 'kitchen%'
        order by tablename`,
    );

    expect(result.rows.map((row) => row.tablename)).toEqual([
      "kitchen_station_menu_categories",
      "kitchen_station_menu_items",
      "kitchen_stations",
      "kitchen_ticket_items",
      "kitchen_tickets",
    ]);
  });

  it("uses full replica identity only for route delete delivery", async () => {
    const client = await createClient();
    track(client);

    const result = await client.query<{
      relname: string;
      relreplident: string;
    }>(
      `select c.relname, c.relreplident
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname in (
            'kitchen_tickets',
            'kitchen_ticket_items',
            'kitchen_stations',
            'kitchen_station_menu_items',
            'kitchen_station_menu_categories'
          )
        order by c.relname`,
    );

    const identity = Object.fromEntries(
      result.rows.map((row) => [row.relname, row.relreplident]),
    );

    expect(identity.kitchen_station_menu_items).toBe("f");
    expect(identity.kitchen_station_menu_categories).toBe("f");
    expect(identity.kitchen_tickets).toBe("d");
    expect(identity.kitchen_ticket_items).toBe("d");
    expect(identity.kitchen_stations).toBe("d");
  });
});
