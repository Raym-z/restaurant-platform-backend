import { z } from "zod";

import { UtcInstantSchema } from "./time.js";

export const SortDirectionSchema = z.enum(["asc", "desc"]);

export type SortDirection = z.infer<typeof SortDirectionSchema>;

/**
 * Build a sort contract restricted to an explicit allowlist. Clients must
 * never supply arbitrary database column names.
 */
export const createSortSchema = <
  const T extends readonly [string, ...string[]],
>(
  allowedFields: T,
) =>
  z
    .object({
      field: z.enum(allowedFields),
      direction: SortDirectionSchema.default("asc"),
    })
    .strict();

export const DateRangeSchema = z
  .object({
    from: UtcInstantSchema.optional(),
    to: UtcInstantSchema.optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.from === undefined || value.to === undefined) {
      return;
    }

    if (Date.parse(value.from) > Date.parse(value.to)) {
      ctx.addIssue({
        code: "custom",
        path: ["from"],
        message: "Must be before or equal to the end of the range",
      });
    }
  });

export type DateRange = z.infer<typeof DateRangeSchema>;

export const SearchQuerySchema = z.string().trim().min(1).max(200);

export type SearchQuery = z.infer<typeof SearchQuerySchema>;
