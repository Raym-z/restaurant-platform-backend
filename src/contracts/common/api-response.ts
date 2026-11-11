import { z } from "zod";

import { ApiErrorPayloadSchema, type ApiErrorPayload } from "./errors.ts";

/**
 * Free-form response metadata. Pagination metadata is defined separately and
 * may be placed under this object by collection endpoints.
 */
export const ApiMetaSchema = z.record(z.string(), z.unknown()).nullable();

export type ApiMeta = z.infer<typeof ApiMetaSchema>;

/**
 * Consistent success envelope for trusted Edge Function/API endpoints.
 *
 * Direct Supabase queries retain their native response shape unless wrapped
 * by an application service.
 */
export const apiSuccessSchema = <T extends z.ZodType>(dataSchema: T) =>
  z
    .object({
      success: z.literal(true),
      data: dataSchema,
      meta: ApiMetaSchema.default(null),
    })
    .strict();

export const ApiErrorResponseSchema = z
  .object({
    success: z.literal(false),
    error: ApiErrorPayloadSchema,
  })
  .strict();

export type ApiErrorResponse = z.infer<typeof ApiErrorResponseSchema>;

export type ApiSuccess<T> = {
  success: true;
  data: T;
  meta: ApiMeta;
};

export type ApiResponse<T> = ApiSuccess<T> | ApiErrorResponse;

export type ApiErrorPayloadInput = Omit<ApiErrorPayload, "details"> & {
  details?: ApiErrorPayload["details"];
};

export const apiSuccess = <T>(
  data: T,
  meta: ApiMeta = null,
): ApiSuccess<T> => ({
  success: true,
  data,
  meta,
});

export const apiFailure = (error: ApiErrorPayloadInput): ApiErrorResponse => ({
  success: false,
  error: {
    ...error,
    details: error.details ?? null,
  },
});
