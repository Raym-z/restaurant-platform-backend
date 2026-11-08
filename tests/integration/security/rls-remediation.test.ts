import type pg from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { createClient } from "../setup/db.js";
import {
  authenticateAs,
  createCustomer,
  createOrgFixture,
  createPlatformAdmin,
} from "./helpers.js";

const clients: pg.Client[] = [];

afterAll(async () => {
  await Promise.all(
    clients.map((client) => client.end().catch(() => undefined)),
  );
});

describe("RLS and helper grant remediation", () => {
  it("restricts plan visibility to staff", async () => {
    const admin = await createClient();
    const owner = await createClient();
    const customerClient = await createClient();
    clients.push(admin, owner, customerClient);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    const customer = await createCustomer(admin);

    await authenticateAs(customerClient, customer.authUserId);
    const customerPlans = await customerClient.query<{ count: string }>(
      "select count(*)::text as count from public.plans",
    );
    expect(Number(customerPlans.rows[0]!.count)).toBe(0);

    await authenticateAs(owner, fixture.ownerAuthUserId);
    const ownerPlans = await owner.query<{ count: string }>(
      "select count(*)::text as count from public.plans",
    );
    expect(Number(ownerPlans.rows[0]!.count)).toBeGreaterThan(0);
  });

  it("allows platform admins to read the plan catalog", async () => {
    const admin = await createClient();
    const platform = await createClient();
    clients.push(admin, platform);

    await createOrgFixture(admin, { branchCount: 1 });
    const platformAdmin = await createPlatformAdmin(admin);

    await authenticateAs(platform, platformAdmin.authUserId);
    const plans = await platform.query<{ count: string }>(
      "select count(*)::text as count from public.plans",
    );

    expect(Number(plans.rows[0]!.count)).toBeGreaterThan(0);
  });

  it("revokes authenticated execution of subscription-state helpers", async () => {
    const admin = await createClient();
    const owner = await createClient();
    clients.push(admin, owner);

    const fixture = await createOrgFixture(admin, { branchCount: 1 });
    await authenticateAs(owner, fixture.ownerAuthUserId);

    await expect(
      owner.query("select authz.org_subscription_state($1)", [
        fixture.organizationId,
      ]),
    ).rejects.toThrow(/permission denied/i);
  });
});
