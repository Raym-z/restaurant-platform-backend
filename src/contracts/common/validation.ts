import { z } from "zod";

export const ValidationIssueSchema = z
  .object({
    path: z.array(z.string()),
    message: z.string().min(1),
    code: z.string().min(1),
  })
  .strict();

export type ValidationIssue = z.infer<typeof ValidationIssueSchema>;

export const toValidationIssues = (error: z.ZodError): ValidationIssue[] =>
  error.issues.map((issue) => ({
    path: issue.path.map((part) => String(part)),
    message: issue.message,
    code: issue.code,
  }));

export const parseWithSchema = <T>(schema: z.ZodType<T>, value: unknown): T =>
  schema.parse(value);
