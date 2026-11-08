import { describe, expect, it } from "vitest";

import {
  GuestOrderSummarySchema,
  GuestSessionContextSchema,
} from "../../src/contracts/guest/session.ts";
import {
  UtcInstantSchema,
  normalizeUtcInstant,
} from "../../src/contracts/common/time.ts";
import { toGuestSessionContext } from "../../supabase/functions/_shared/guest.ts";

const session = {
  sessionId: "00000000-0000-4000-8000-000000000001",
  organizationId: "00000000-0000-4000-8000-000000000002",
  branchId: "00000000-0000-4000-8000-000000000003",
  tableId: "00000000-0000-4000-8000-000000000004",
  tableLabel: "T1",
  branchName: "Main",
  timezone: "Asia/Jakarta",
  currency: "IDR",
  status: "active",
  openedAt: "2026-11-08T17:00:00+07:00",
} as const;

describe("timestamp normalization", () => {
  it("normalizes offsets and Z to UTC Z with microseconds", () => {
    expect(UtcInstantSchema.parse("2026-11-08T10:00:00Z")).toBe(
      "2026-11-08T10:00:00.000000Z",
    );
    expect(UtcInstantSchema.parse("2026-11-08T17:00:00+07:00")).toBe(
      "2026-11-08T10:00:00.000000Z",
    );
    expect(UtcInstantSchema.parse("2026-11-08T10:00:00+00:00")).toBe(
      "2026-11-08T10:00:00.000000Z",
    );
  });

  it("normalizes the session context returned by PostgREST-style JSON", () => {
    const parsed = GuestSessionContextSchema.parse(session);
    expect(parsed.openedAt).toBe("2026-11-08T10:00:00.000000Z");
  });

  it("normalizes the Edge context mapper output", () => {
    const parsed = toGuestSessionContext(session);
    expect(parsed.openedAt).toBe("2026-11-08T10:00:00.000000Z");
  });

  it("normalizes order summary timestamps", () => {
    const parsed = GuestOrderSummarySchema.parse({
      orderId: "00000000-0000-4000-8000-000000000005",
      status: "pending",
      subtotalMinor: 25000,
      createdAt: "2026-11-08T17:00:00+07:00",
      items: [],
    });

    expect(parsed.createdAt).toBe("2026-11-08T10:00:00.000000Z");
  });

  it("accepts leap days and preserves six-digit fractions", () => {
    expect(UtcInstantSchema.parse("2024-02-29T23:59:59.123456Z")).toBe(
      "2024-02-29T23:59:59.123456Z",
    );
    expect(UtcInstantSchema.parse("2026-11-08T10:00:00.123456+00:00")).toBe(
      "2026-11-08T10:00:00.123456Z",
    );
  });

  it("rejects invalid calendar dates and times", () => {
    for (const value of [
      "2026-02-30T10:00:00Z",
      "2026-04-31T10:00:00Z",
      "2026-11-08T24:00:00Z",
      "2023-02-29T10:00:00Z",
      "2026-11-08T10:60:00Z",
      "2026-11-08T10:00:60Z",
    ]) {
      expect(normalizeUtcInstant(value)).toBeNull();
      expect(UtcInstantSchema.safeParse(value).success).toBe(false);
    }
  });

  it("rejects malformed and invalid offsets", () => {
    for (const value of [
      "2026-11-08T10:00:00",
      "2026-11-08T10:00:00+25:00",
      "2026-11-08T10:00:00+14:01",
      "2026-11-08T10:00:00+07:60",
      "2026-11-08T10:00:00.1234567Z",
    ]) {
      expect(normalizeUtcInstant(value)).toBeNull();
      expect(UtcInstantSchema.safeParse(value).success).toBe(false);
    }
  });

  it("accepts the maximum valid offset", () => {
    expect(UtcInstantSchema.parse("2026-11-08T00:00:00+14:00")).toBe(
      "2026-11-07T10:00:00.000000Z",
    );
  });
});
