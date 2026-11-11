/**
 * Minimal Deno global surface for loading shared Edge Function helpers in
 * Vitest. Edge Functions themselves are type-checked with `deno check`.
 */
declare namespace Deno {
  const env: {
    get(name: string): string | undefined;
  };

  function test(name: string, fn: () => void | Promise<void>): void;
}
