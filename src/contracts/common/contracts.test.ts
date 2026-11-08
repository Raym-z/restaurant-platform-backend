import { describe, expect, it } from "vitest";
import { z } from "zod";

import {
  API_ERROR_CODES,
  ApiErrorCodeSchema,
  ApiErrorPayloadSchema,
  AppError,
  GrantStaffRoleRequestSchema,
  GrantStaffRoleResponseSchema,
  GuestSessionContextSchema,
  HTTP_STATUS_BY_ERROR_CODE,
  PermissionKeySchema,
  ResolveTableResponseSchema,
  StaffRoleAssignmentSchema,
  SubmitGuestOrderRequestSchema,
  UtcInstantSchema,
  apiFailure,
  apiSuccess,
  apiSuccessSchema,
  toValidationIssues,
} from "../../index.ts";

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
  openedAt: "2026-11-08T10:00:00Z",
} as const;

describe("API envelopes", () => {
  it("accepts a success envelope", () => {
    const schema = apiSuccessSchema(z.object({ id: z.string() }));
    expect(schema.parse(apiSuccess({ id: "x" }))).toEqual({
      success: true,
      data: { id: "x" },
      meta: null,
    });
  });

  it("accepts an error envelope", () => {
    const failure = apiFailure({
      code: "PERMISSION_DENIED",
      message: "Denied",
    });

    expect(failure).toEqual({
      success: false,
      error: {
        code: "PERMISSION_DENIED",
        message: "Denied",
        details: null,
      },
    });
  });

  it("rejects unknown error codes", () => {
    expect(
      ApiErrorPayloadSchema.safeParse({ code: "NOT_A_CODE", message: "x" })
        .success,
    ).toBe(false);
  });

  it("maps every declared error code to an HTTP status", () => {
    const mapped = Object.keys(HTTP_STATUS_BY_ERROR_CODE).sort();
    expect(mapped).toEqual([...API_ERROR_CODES].sort());
    expect(ApiErrorCodeSchema.options.length).toBe(API_ERROR_CODES.length);
  });

  it("produces safe AppError payloads", () => {
    const error = new AppError("ORDER_INVALID_STATUS", "Invalid status");

    expect(error.httpStatus).toBe(409);
    expect(error.toPayload()).toEqual({
      code: "ORDER_INVALID_STATUS",
      message: "Invalid status",
      details: null,
    });
  });

  it("converts Zod issues to serializable details", () => {
    const schema = apiSuccessSchema(z.object({ id: z.string() }));
    const result = schema.safeParse({ success: true, data: { id: 1 } });

    expect(result.success).toBe(false);
    if (!result.success) {
      const issues = toValidationIssues(result.error);
      expect(issues[0]?.path).toEqual(["data", "id"]);
    }
  });
});

describe("role scope contracts", () => {
  it("requires Owner to be organization-scoped", () => {
    expect(
      StaffRoleAssignmentSchema.safeParse({
        role: "owner",
        scope: "branch",
        branchId: session.branchId,
      }).success,
    ).toBe(false);
  });

  it("allows organization-scoped Admin", () => {
    expect(
      StaffRoleAssignmentSchema.safeParse({
        role: "admin",
        scope: "organization",
        branchId: null,
      }).success,
    ).toBe(true);
  });

  it("allows branch-scoped Admin, Manager, Cashier, and Kitchen Staff", () => {
    for (const role of [
      "admin",
      "manager",
      "cashier",
      "kitchen_staff",
    ] as const) {
      expect(
        StaffRoleAssignmentSchema.safeParse({
          role,
          scope: "branch",
          branchId: session.branchId,
        }).success,
      ).toBe(true);
    }
  });

  it("rejects a branch-scoped assignment without a branch", () => {
    expect(
      StaffRoleAssignmentSchema.safeParse({
        role: "cashier",
        scope: "branch",
        branchId: null,
      }).success,
    ).toBe(false);
  });

  it("allows the same staff member to hold different roles at two branches", () => {
    const managerAtA = StaffRoleAssignmentSchema.parse({
      role: "manager",
      scope: "branch",
      branchId: session.branchId,
    });
    const cashierAtB = StaffRoleAssignmentSchema.parse({
      role: "cashier",
      scope: "branch",
      branchId: "00000000-0000-4000-8000-000000000005",
    });

    expect(managerAtA.branchId).toBe(session.branchId);
    expect(cashierAtB.role).toBe("cashier");
  });
});

describe("staff role grant contracts", () => {
  it("requires a branch identifier for branch-scoped grants", () => {
    expect(
      GrantStaffRoleRequestSchema.safeParse({
        staffId: session.tableId,
        role: "manager",
        scope: "branch",
        reason: "Open the second branch",
      }).success,
    ).toBe(false);
  });

  it("rejects a branch identifier on organization-scoped grants", () => {
    expect(
      GrantStaffRoleRequestSchema.safeParse({
        staffId: session.tableId,
        role: "admin",
        scope: "organization",
        branchId: session.branchId,
      }).success,
    ).toBe(false);
  });

  it("accepts a branch-scoped grant with a branch identifier", () => {
    expect(
      GrantStaffRoleRequestSchema.safeParse({
        staffId: session.tableId,
        role: "cashier",
        scope: "branch",
        branchId: session.branchId,
        reason: "Cashier at the main branch",
      }).success,
    ).toBe(true);
  });

  it("requires the response to state the branch, including null for organization scope", () => {
    const branchResponse = GrantStaffRoleResponseSchema.parse({
      assignmentId: session.sessionId,
      staffId: session.tableId,
      roleCode: "manager",
      scope: "branch",
      branchId: session.branchId,
    });
    const organizationResponse = GrantStaffRoleResponseSchema.parse({
      assignmentId: session.sessionId,
      staffId: session.tableId,
      roleCode: "admin",
      scope: "organization",
      branchId: null,
    });

    expect(branchResponse.branchId).toBe(session.branchId);
    expect(organizationResponse.branchId).toBeNull();
  });
});

describe("permission key contracts", () => {
  it("accepts dotted lowercase permission keys", () => {
    expect(PermissionKeySchema.safeParse("order.accept").success).toBe(true);
    expect(
      PermissionKeySchema.safeParse("subscription.contact.manage").success,
    ).toBe(true);
  });

  it("rejects malformed permission keys", () => {
    expect(PermissionKeySchema.safeParse("Order Accept").success).toBe(false);
    expect(PermissionKeySchema.safeParse("order").success).toBe(false);
  });
});

describe("guest contracts", () => {
  it("accepts a resolve-table response with a raw token", () => {
    const response = ResolveTableResponseSchema.parse({
      session,
      guestToken: "a".repeat(48),
      tokenExpiresAt: "2026-11-08T12:00:00Z",
    });

    expect(response.session.status).toBe("active");
    expect(response.guestToken).toHaveLength(48);
  });

  it("rejects invalid session status values", () => {
    expect(
      GuestSessionContextSchema.safeParse({ ...session, status: "bogus" })
        .success,
    ).toBe(false);
  });

  it("accepts a guest order request without client totals", () => {
    expect(
      SubmitGuestOrderRequestSchema.safeParse({
        guestToken: "a".repeat(48),
        idempotencyKey: "idem-key-1234567890",
        items: [
          {
            menuItemId: session.tableId,
            quantity: 2,
            modifierOptionIds: [],
          },
        ],
      }).success,
    ).toBe(true);
  });

  it("rejects an empty guest order", () => {
    expect(
      SubmitGuestOrderRequestSchema.safeParse({
        guestToken: "a".repeat(48),
        idempotencyKey: "idem-key-1234567890",
        items: [],
      }).success,
    ).toBe(false);
  });
});

describe("time contracts", () => {
  it("normalizes UTC and offset timestamps to Z", () => {
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

  it("rejects malformed or invalid timestamps", () => {
    expect(UtcInstantSchema.safeParse("2026-11-08T10:00:00").success).toBe(
      false,
    );
    expect(UtcInstantSchema.safeParse("2026-13-40T10:00:00Z").success).toBe(
      false,
    );
  });
});
