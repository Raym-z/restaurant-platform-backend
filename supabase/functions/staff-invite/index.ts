import { apiFailure } from "../../../src/contracts/common/api-response.ts";
import { AppError } from "../../../src/lib/errors.ts";
import {
  StaffInvitationSchema,
  StaffInviteEdgeRequestSchema,
  type StaffInvitation,
} from "../../../src/contracts/staff/invitation.ts";
import type { StaffInviteEnv } from "../_shared/env.ts";
import { getStaffInviteEnv } from "../_shared/env.ts";
import {
  errorResponse,
  jsonResponse,
  optionsResponse,
  readJsonBody,
  successResponse,
} from "../_shared/http.ts";
import { callRpc } from "../_shared/rpc.ts";
import {
  buildAcceptanceRedirect,
  INVITATION_DELIVERY_FAILURE_MESSAGE,
  normalizeInvitationEmail,
} from "../_shared/staffInvite.ts";
import { deliverStaffInvitationEmail } from "../_shared/staffInviteDelivery.ts";
import {
  createStaffAnonClient,
  createStaffServiceClient,
  createStaffUserClient,
} from "../_shared/supabase.ts";
import { generateInvitationToken, sha256Hex } from "../_shared/token.ts";

const bearerToken = (request: Request): string => {
  const header = request.headers.get("authorization");

  if (header === null) {
    throw new AppError("AUTH_REQUIRED", "Authentication is required");
  }

  const match = header.match(/^Bearer\s+(.+)$/i);
  if (match === null || match[1].trim() === "") {
    throw new AppError("AUTH_INVALID_TOKEN", "Authentication is invalid");
  }

  return match[1].trim();
};

const deliverInvitationEmail = async (
  email: string,
  redirectTo: string,
): Promise<void> => {
  const result = await deliverStaffInvitationEmail(
    {
      admin: createStaffServiceClient(),
      anon: createStaffAnonClient(),
    },
    email,
    redirectTo,
  );

  if (!result.ok) {
    throw new AppError(
      "INVITATION_DELIVERY_FAILED",
      INVITATION_DELIVERY_FAILURE_MESSAGE,
    );
  }
};

const revokeAfterDeliveryFailure = async (
  userClient: ReturnType<typeof createStaffUserClient>,
  invitationId: string,
): Promise<void> => {
  try {
    await callRpc(userClient, "revoke_staff_invitation", {
      p_invitation_id: invitationId,
      p_reason: "Invitation delivery failed",
    });
  } catch {
    // Best-effort compensating action. The invitation remains single-use and
    // expires even if this call fails.
  }
};

Deno.serve(async (request: Request): Promise<Response> => {
  let env: StaffInviteEnv | null = null;

  try {
    env = getStaffInviteEnv();

    if (request.method === "OPTIONS") {
      return optionsResponse(request, env);
    }

    if (request.method !== "POST") {
      return jsonResponse(
        apiFailure({
          code: "VALIDATION_ERROR",
          message: "Only POST is supported",
        }),
        405,
        request,
        env,
      );
    }

    const token = bearerToken(request);
    const userClient = createStaffUserClient(token);

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser(token);

    if (authError !== null || user === null) {
      throw new AppError("AUTH_INVALID_TOKEN", "Authentication is invalid");
    }

    const input = StaffInviteEdgeRequestSchema.parse(
      await readJsonBody(request),
    );

    const rawToken = generateInvitationToken();
    const tokenHash = await sha256Hex(rawToken);
    const expiresAt = new Date(
      Date.now() + env.invitationTtlSeconds * 1000,
    ).toISOString();
    const redirectTo = buildAcceptanceRedirect(env.acceptanceUrl, rawToken);

    let invitation: StaffInvitation;

    if (input.action === "invite") {
      const data = await callRpc<unknown>(
        userClient,
        "create_staff_invitation",
        {
          p_email: normalizeInvitationEmail(input.email),
          p_display_name: input.displayName.trim(),
          p_role_code: input.role,
          p_scope_type: input.scope,
          p_branch_id: input.branchId ?? null,
          p_token_hash_hex: tokenHash,
          p_expires_at: expiresAt,
          p_reason: input.reason ?? null,
        },
      );

      invitation = StaffInvitationSchema.parse(data);

      try {
        await deliverInvitationEmail(invitation.email, redirectTo);
      } catch (error) {
        await revokeAfterDeliveryFailure(userClient, invitation.invitationId);
        throw error;
      }
    } else {
      const data = await callRpc<unknown>(
        userClient,
        "rotate_staff_invitation_token",
        {
          p_invitation_id: input.invitationId,
          p_token_hash_hex: tokenHash,
          p_expires_at: expiresAt,
        },
      );

      invitation = StaffInvitationSchema.parse(data);

      try {
        await deliverInvitationEmail(invitation.email, redirectTo);
      } catch (error) {
        await revokeAfterDeliveryFailure(userClient, invitation.invitationId);
        throw error;
      }
    }

    return successResponse(
      invitation,
      request,
      env,
      input.action === "invite" ? 201 : 200,
    );
  } catch (error) {
    return errorResponse(error, request, env);
  }
});
