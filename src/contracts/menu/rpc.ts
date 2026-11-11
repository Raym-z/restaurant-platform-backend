import { z } from "zod";

import { UuidSchema } from "../common/ids.ts";
import { MinorUnitsSchema } from "../common/money.ts";

export const CreateMenuCategoryRequestSchema = z
  .object({
    name: z.string().trim().min(1).max(200),
    description: z.string().trim().max(1000).optional(),
    sortOrder: z.number().int().default(0),
  })
  .strict();

export type CreateMenuCategoryRequest = z.infer<
  typeof CreateMenuCategoryRequestSchema
>;

export const UpdateMenuCategoryRequestSchema = z
  .object({
    categoryId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    description: z.string().trim().max(1000).optional(),
    sortOrder: z.number().int().default(0),
  })
  .strict();

export type UpdateMenuCategoryRequest = z.infer<
  typeof UpdateMenuCategoryRequestSchema
>;

export const MenuCategoryResponseSchema = z
  .object({ categoryId: UuidSchema })
  .strict();

export type MenuCategoryResponse = z.infer<typeof MenuCategoryResponseSchema>;

export const CreateMenuItemRequestSchema = z
  .object({
    categoryId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    basePriceMinor: MinorUnitsSchema.min(0),
    description: z.string().trim().max(1000).optional(),
    sortOrder: z.number().int().default(0),
  })
  .strict();

export type CreateMenuItemRequest = z.infer<typeof CreateMenuItemRequestSchema>;

export const UpdateMenuItemRequestSchema = z
  .object({
    menuItemId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    basePriceMinor: MinorUnitsSchema.min(0),
    description: z.string().trim().max(1000).optional(),
    sortOrder: z.number().int().default(0),
  })
  .strict();

export type UpdateMenuItemRequest = z.infer<typeof UpdateMenuItemRequestSchema>;

export const MenuItemResponseSchema = z
  .object({ menuItemId: UuidSchema })
  .strict();

export type MenuItemResponse = z.infer<typeof MenuItemResponseSchema>;

export const UpdateBaseItemPriceRequestSchema = z
  .object({
    menuItemId: UuidSchema,
    basePriceMinor: MinorUnitsSchema.min(0),
  })
  .strict();

export type UpdateBaseItemPriceRequest = z.infer<
  typeof UpdateBaseItemPriceRequestSchema
>;

export const CreateModifierGroupRequestSchema = z
  .object({
    name: z.string().trim().min(1).max(200),
    description: z.string().trim().max(1000).optional(),
    minSelections: z.number().int().min(0).default(0),
    maxSelections: z.number().int().min(1).default(1),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.minSelections > value.maxSelections) {
      ctx.addIssue({
        code: "custom",
        path: ["minSelections"],
        message: "Minimum selections cannot exceed maximum selections",
      });
    }
  });

export type CreateModifierGroupRequest = z.infer<
  typeof CreateModifierGroupRequestSchema
>;

export const ModifierGroupResponseSchema = z
  .object({ modifierGroupId: UuidSchema })
  .strict();

export type ModifierGroupResponse = z.infer<typeof ModifierGroupResponseSchema>;

export const CreateModifierOptionRequestSchema = z
  .object({
    modifierGroupId: UuidSchema,
    name: z.string().trim().min(1).max(200),
    priceDeltaMinor: MinorUnitsSchema.default(0),
    sortOrder: z.number().int().default(0),
  })
  .strict();

export type CreateModifierOptionRequest = z.infer<
  typeof CreateModifierOptionRequestSchema
>;

export const ModifierOptionResponseSchema = z
  .object({ modifierOptionId: UuidSchema })
  .strict();

export type ModifierOptionResponse = z.infer<
  typeof ModifierOptionResponseSchema
>;

export const AssignModifierGroupRequestSchema = z
  .object({
    menuItemId: UuidSchema,
    modifierGroupId: UuidSchema,
    sortOrder: z.number().int().default(0),
  })
  .strict();

export type AssignModifierGroupRequest = z.infer<
  typeof AssignModifierGroupRequestSchema
>;

export const SetBranchItemAvailabilityRequestSchema = z
  .object({
    branchId: UuidSchema,
    menuItemId: UuidSchema,
    isAvailable: z.boolean(),
  })
  .strict();

export type SetBranchItemAvailabilityRequest = z.infer<
  typeof SetBranchItemAvailabilityRequestSchema
>;

export const SetBranchPriceOverrideRequestSchema = z
  .object({
    branchId: UuidSchema,
    menuItemId: UuidSchema,
    priceMinor: MinorUnitsSchema.min(0),
  })
  .strict();

export type SetBranchPriceOverrideRequest = z.infer<
  typeof SetBranchPriceOverrideRequestSchema
>;

export const RemoveBranchPriceOverrideRequestSchema = z
  .object({
    branchId: UuidSchema,
    menuItemId: UuidSchema,
  })
  .strict();

export type RemoveBranchPriceOverrideRequest = z.infer<
  typeof RemoveBranchPriceOverrideRequestSchema
>;
