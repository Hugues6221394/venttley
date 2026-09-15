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
