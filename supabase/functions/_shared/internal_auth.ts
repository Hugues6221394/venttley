const MAX_INTERNAL_SECRET_BYTES = 512;

/** Fixed-work comparison for short, pre-shared service credentials. */
export function secretsMatch(presented: string, expected: string): boolean {
  const encoder = new TextEncoder();
  const left = encoder.encode(presented);
  const right = encoder.encode(expected);
  if (
    left.length > MAX_INTERNAL_SECRET_BYTES ||
    right.length > MAX_INTERNAL_SECRET_BYTES
  ) return false;
  let difference = left.length ^ right.length;

  for (let index = 0; index < MAX_INTERNAL_SECRET_BYTES; index++) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

export type InternalAuthResult =
  | { ok: true }
  | { ok: false; status: 401 | 500; error: string };

/**
 * Authenticate a cron or Database Webhook before constructing an admin
 * client. Missing server configuration fails closed and is distinguishable
 * from a bad caller credential without logging either secret.
 */
export function verifyInternalSecret(
  request: Request,
  options: {
    envName: string;
    headerName: "x-cron-secret" | "x-webhook-secret";
    expected?: string | null;
  },
): InternalAuthResult {
  const expected = options.expected ?? Deno.env.get(options.envName);
  const expectedLength = expected == null
    ? 0
    : new TextEncoder().encode(expected).length;
  if (
    expected == null ||
    expectedLength < 32 ||
    expectedLength > MAX_INTERNAL_SECRET_BYTES
  ) {
    return { ok: false, status: 500, error: "internal_auth_not_configured" };
  }
  const presented = request.headers.get(options.headerName) ?? "";
  if (!secretsMatch(presented, expected)) {
    return { ok: false, status: 401, error: "unauthorized" };
  }
  return { ok: true };
}

/** Risky or destructive workers are opt-in in every environment. */
export function rolloutEnabled(
  envName: string,
  value?: string | null,
): boolean {
  const configured = (value ?? Deno.env.get(envName) ?? "").trim()
    .toLowerCase();
  return configured === "on" || configured === "true" || configured === "1";
}
