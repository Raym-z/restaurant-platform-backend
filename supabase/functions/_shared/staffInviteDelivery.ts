import {
  isExistingAuthUserError,
  type AuthAdminErrorLike,
} from "./staffInvite.ts";

export type InvitationDeliveryClients = {
  admin: {
    auth: {
      admin: {
        inviteUserByEmail(
          email: string,
          options: { redirectTo: string },
        ): Promise<{ error: AuthAdminErrorLike | null }>;
      };
    };
  };
  anon: {
    auth: {
      signInWithOtp(args: {
        email: string;
        options: {
          shouldCreateUser: boolean;
          emailRedirectTo: string;
        };
      }): Promise<{ error: AuthAdminErrorLike | null }>;
    };
  };
};

export type InvitationDeliveryResult =
  { ok: true } | { ok: false; reason: "delivery_failed" };

/**
 * Deliver an invitation email.
 *
 * New addresses receive a Supabase Auth invitation. Existing addresses receive a
 * magic link instead, because Supabase refuses to invite an existing account.
 * The caller must not distinguish between the two outcomes.
 */
export const deliverStaffInvitationEmail = async (
  clients: InvitationDeliveryClients,
  email: string,
  redirectTo: string,
): Promise<InvitationDeliveryResult> => {
  const invite = await clients.admin.auth.admin.inviteUserByEmail(email, {
    redirectTo,
  });

  if (invite.error === null) {
    return { ok: true };
  }

  if (isExistingAuthUserError(invite.error)) {
    const otp = await clients.anon.auth.signInWithOtp({
      email,
      options: {
        shouldCreateUser: false,
        emailRedirectTo: redirectTo,
      },
    });

    if (otp.error === null) {
      return { ok: true };
    }
  }

  return { ok: false, reason: "delivery_failed" };
};
