import { z } from "zod";

import {
  IdempotencyKeySchema,
  PhoneE164Schema,
  UuidSchema,
} from "../common/ids.ts";
import { UtcInstantSchema } from "../common/time.ts";

export const WAITLIST_STATUSES = [
  "waiting",
  "notified",
  "seated",
  "cancelled",
  "no_show",
] as const;

export type WaitlistStatus = (typeof WAITLIST_STATUSES)[number];

export const WaitlistStatusSchema = z.enum(WAITLIST_STATUSES);

export const JoinWaitlistRequestSchema = z
  .object({
    branchId: UuidSchema,
    partySize: z.number().int().min(1).max(32767),
    contactName: z.string().trim().max(200).optional(),
    contactPhone: PhoneE164Schema.optional(),
    locationLat: z.number().min(-90).max(90).optional(),
    locationLng: z.number().min(-180).max(180).optional(),
    idempotencyKey: IdempotencyKeySchema.optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (
      (value.locationLat === undefined) !==
      (value.locationLng === undefined)
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["locationLat"],
        message: "Latitude and longitude must be provided together",
      });
    }
  });

export type JoinWaitlistRequest = z.infer<typeof JoinWaitlistRequestSchema>;

export const JoinWaitlistResponseSchema = z
  .object({
    entryId: UuidSchema,
    branchId: UuidSchema,
    status: WaitlistStatusSchema,
    joinedAt: UtcInstantSchema,
  })
  .strict();

export type JoinWaitlistResponse = z.infer<typeof JoinWaitlistResponseSchema>;

export const UpdateWaitlistStatusRequestSchema = z
  .object({
    entryId: UuidSchema,
    status: WaitlistStatusSchema,
    reason: z.string().trim().max(500).optional(),
  })
  .strict();

export type UpdateWaitlistStatusRequest = z.infer<
  typeof UpdateWaitlistStatusRequestSchema
>;

export const WaitlistStatusResponseSchema = z
  .object({
    entryId: UuidSchema,
    status: WaitlistStatusSchema,
  })
  .strict();

export type WaitlistStatusResponse = z.infer<
  typeof WaitlistStatusResponseSchema
>;

export const WaitlistPositionResponseSchema = z
  .object({
    entryId: UuidSchema,
    position: z.number().int().min(1),
    status: WaitlistStatusSchema,
  })
  .strict();

export type WaitlistPositionResponse = z.infer<
  typeof WaitlistPositionResponseSchema
>;

export const CancelWaitlistEntryRequestSchema = z
  .object({
    entryId: UuidSchema,
    reason: z.string().trim().max(500).optional(),
  })
  .strict();

export type CancelWaitlistEntryRequest = z.infer<
  typeof CancelWaitlistEntryRequestSchema
>;
