import assert from "node:assert/strict";

import {
  generateGuestToken,
  sha256Hex,
} from "../../supabase/functions/_shared/token.ts";
import { toGuestSessionContext } from "../../supabase/functions/_shared/guest.ts";

Deno.test(
  "guest token generation is opaque, high-entropy, and hashable",
  async () => {
    const first = generateGuestToken();
    const second = generateGuestToken();

    assert.equal(first.length, 43);
    assert.match(first, /^[A-Za-z0-9_-]+$/);
    assert.equal(first === second, false);

    const hash = await sha256Hex(first);
    assert.equal(hash.length, 64);
    assert.match(hash, /^[0-9a-f]{64}$/);
    assert.equal(await sha256Hex(first), hash);
  },
);

Deno.test("Edge context mapping normalizes PostgREST offset timestamps", () => {
  const context = toGuestSessionContext({
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
  });

  assert.equal(context.openedAt, "2026-11-08T10:00:00.000000Z");
});
