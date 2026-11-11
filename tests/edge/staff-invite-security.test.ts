import assert from "node:assert/strict";

import {
  buildAcceptanceRedirect,
  INVITATION_DELIVERY_FAILURE_MESSAGE,
  isExistingAuthUserError,
  normalizeInvitationEmail,
} from "../../supabase/functions/_shared/staffInvite.ts";
import {
  generateInvitationToken,
  sha256Hex,
} from "../../supabase/functions/_shared/token.ts";
import { deliverStaffInvitationEmail } from "../../supabase/functions/_shared/staffInviteDelivery.ts";

Deno.test("invitation tokens are opaque and hashable", async () => {
  const first = generateInvitationToken();
  const second = generateInvitationToken();

  assert.equal(first.length, 43);
  assert.match(first, /^[A-Za-z0-9_-]+$/);
  assert.notEqual(first, second);

  const hash = await sha256Hex(first);
  assert.match(hash, /^[0-9a-f]{64}$/);
});

Deno.test(
  "invitation email normalization and error classification are stable",
  () => {
    assert.equal(
      normalizeInvitationEmail("  Staff@Example.Test "),
      "staff@example.test",
    );
    assert.equal(
      isExistingAuthUserError({
        message: "A user with this email address has already been registered",
      }),
      true,
    );
    assert.equal(
      isExistingAuthUserError({ message: "Email rate limit exceeded" }),
      false,
    );
  },
);

Deno.test(
  "acceptance redirect carries the token without losing query parameters",
  () => {
    const redirect = buildAcceptanceRedirect(
      "https://pos.example.test/accept-invitation?source=email",
      "abc_DEF-123",
    );
    const url = new URL(redirect);

    assert.equal(url.pathname, "/accept-invitation");
    assert.equal(url.searchParams.get("source"), "email");
    assert.equal(url.searchParams.get("invitation"), "abc_DEF-123");
  },
);

Deno.test("delivery failure message never implies account access", () => {
  assert.match(
    INVITATION_DELIVERY_FAILURE_MESSAGE,
    /No account access was granted/i,
  );
  assert.doesNotMatch(INVITATION_DELIVERY_FAILURE_MESSAGE, /existing/i);
});

const deliveryClients = (options: {
  inviteError: { message: string } | null;
  otpError: { message: string } | null;
}) => {
  let otpCalls = 0;

  return {
    clients: {
      admin: {
        auth: {
          admin: {
            inviteUserByEmail: async () => ({ error: options.inviteError }),
          },
        },
      },
      anon: {
        auth: {
          signInWithOtp: async () => {
            otpCalls += 1;
            return { error: options.otpError };
          },
        },
      },
    },
    otpCalls: () => otpCalls,
  };
};

Deno.test("new Auth account uses the invitation email path", async () => {
  const fake = deliveryClients({ inviteError: null, otpError: null });
  const result = await deliverStaffInvitationEmail(
    fake.clients,
    "new@example.test",
    "https://pos.example.test/accept-invitation?invitation=token",
  );

  assert.deepEqual(result, { ok: true });
  assert.equal(fake.otpCalls(), 0);
});

Deno.test("existing Auth account falls back to a magic link", async () => {
  const fake = deliveryClients({
    inviteError: {
      message: "A user with this email address has already been registered",
    },
    otpError: null,
  });
  const result = await deliverStaffInvitationEmail(
    fake.clients,
    "existing@example.test",
    "https://pos.example.test/accept-invitation?invitation=token",
  );

  assert.deepEqual(result, { ok: true });
  assert.equal(fake.otpCalls(), 1);
});

Deno.test("magic-link failure reports a generic delivery failure", async () => {
  const fake = deliveryClients({
    inviteError: { message: "User already exists" },
    otpError: { message: "Email rate limit exceeded" },
  });
  const result = await deliverStaffInvitationEmail(
    fake.clients,
    "existing@example.test",
    "https://pos.example.test/accept-invitation?invitation=token",
  );

  assert.deepEqual(result, { ok: false, reason: "delivery_failed" });
  assert.equal(fake.otpCalls(), 1);
});

Deno.test(
  "unrelated Auth Admin failure does not attempt a magic link",
  async () => {
    const fake = deliveryClients({
      inviteError: { message: "SMTP is not configured" },
      otpError: null,
    });
    const result = await deliverStaffInvitationEmail(
      fake.clients,
      "new@example.test",
      "https://pos.example.test/accept-invitation?invitation=token",
    );

    assert.deepEqual(result, { ok: false, reason: "delivery_failed" });
    assert.equal(fake.otpCalls(), 0);
  },
);
