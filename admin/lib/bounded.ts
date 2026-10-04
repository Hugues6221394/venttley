/**
 * Preserve input order while limiting concurrent calls to an external system.
 * Useful for Auth Admin lookups, where Promise.all over a large staff set can
 * turn one page load into a provider-side burst.
 */
export async function mapBounded<T, R>(
  items: readonly T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
    throw new Error("concurrency must be a positive integer");
  }
  if (items.length === 0) return [];

  const output = new Array<R>(items.length);
  let next = 0;
  async function run() {
    while (next < items.length) {
      const index = next++;
      output[index] = await worker(items[index], index);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, () => run()),
  );
  return output;
}

export type LookupResult<T> = { status: "fulfilled"; value: T } | { status: "unavailable" };

/** Read-only reconciliation: one failure must not discard successful lookups.
 * The deadline belongs to the whole batch, not to each of hundreds of users.
 * Workers must pass the signal to their transport; late results are ignored.
 * Never use this for mutations: an interrupted write has an ambiguous outcome.
 */
export async function reconcileBounded<T, R>(
  items: readonly T[], concurrency: number, budgetMs: number,
  worker: (item: T, signal: AbortSignal) => Promise<R>,
): Promise<LookupResult<R>[]> {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1 ||
      !Number.isSafeInteger(budgetMs) || budgetMs < 1) throw new Error("Invalid reconciliation bounds");
  const result: LookupResult<R>[] = items.map(() => ({ status: "unavailable" }));
  if (!items.length) return result;
  const controller = new AbortController();
  let next = 0, settled = false;
  const expired = new Promise<void>(resolve => controller.signal.addEventListener("abort", () => resolve(), { once: true }));
  const timer = setTimeout(() => controller.abort(), budgetMs);
  async function run() {
    while (!controller.signal.aborted && !settled && next < items.length) {
      const index = next++;
      try {
        const value = await worker(items[index], controller.signal);
        if (!controller.signal.aborted && !settled) result[index] = { status: "fulfilled", value };
      } catch { /* Unknown only: do not retain errors, account IDs or secrets. */ }
    }
  }
  try {
    await Promise.race([Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, run)), expired]);
    return result;
  } finally {
    settled = true;
    clearTimeout(timer);
    controller.abort();
  }
}

/** Read-only Auth transport: preserve cancellation and redact transport errors.
 * The Auth SDK logs thrown fetch errors; returning a fixed failure response
 * keeps URLs/account identifiers out of that log without reporting success.
 * Do not use for writes, whose interrupted outcome must be reconciled.
 */
export function fetchWithDeadline(signal: AbortSignal, transport: typeof fetch = fetch): typeof fetch {
  return async (input, init) => {
    const original = init?.signal ?? (input instanceof Request ? input.signal : undefined);
    try {
      return await transport(input, { ...init, signal: original ? AbortSignal.any([original, signal]) : signal });
    } catch {
      return new Response('{"message":"Staff lookup unavailable"}', {
        status: 503,
        statusText: "Staff lookup unavailable",
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    }
  };
}
