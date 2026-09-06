/**
 * Input validation for Server Actions and API routes.
 *
 * Every action previously read its input as `String(formData.get(x) ?? "")`
 * and passed it straight to an RPC. That is fine for a browser submitting the
 * rendered form, and meaningless against anything else: a Server Action is a
 * POST endpoint, so `maxLength` on an <input> is a UI hint, not a constraint,
 * and a hand-built request can send any field any value.
 *
 * The database is still the authority — the admin_* RPCs and table CHECK
 * constraints reject bad values on their own. These helpers exist so a bad
 * value is rejected here, with a message naming the field, instead of
 * surfacing as a Postgres constraint error (or, for the unconstrained cases,
 * being accepted).
 *
 * They throw rather than coercing. Silently substituting a default is how an
 * out-of-range rollout percentage becomes a successful-looking write of the
 * wrong number.
 */

export class InvalidInput extends Error {
  constructor(field: string, detail: string) {
    super(`${field}: ${detail}`);
    this.name = "InvalidInput";
  }
}

/** A required, trimmed, length-capped string. */
export function reqStr(fd: FormData, field: string, max: number): string {
  const v = String(fd.get(field) ?? "").trim();
  if (!v) throw new InvalidInput(field, "is required");
  if (v.length > max) {
    throw new InvalidInput(field, `must be ${max} characters or fewer`);
  }
  return v;
}

/** An optional, trimmed, length-capped string. Empty becomes null. */
export function optStr(
  fd: FormData,
  field: string,
  max: number
): string | null {
  const v = String(fd.get(field) ?? "").trim();
  if (!v) return null;
  if (v.length > max) {
    throw new InvalidInput(field, `must be ${max} characters or fewer`);
  }
  return v;
}

/** One of a fixed set. The set matches the database CHECK constraint. */
export function enumOf<const T extends readonly string[]>(
  fd: FormData,
  field: string,
  allowed: T
): T[number] {
  const v = String(fd.get(field) ?? "");
  if (!allowed.includes(v)) {
    throw new InvalidInput(field, `must be one of ${allowed.join(", ")}`);
  }
  return v;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function uuid(fd: FormData, field: string): string {
  const v = String(fd.get(field) ?? "").trim();
  if (!UUID_RE.test(v)) throw new InvalidInput(field, "must be a UUID");
  return v;
}

/**
 * A capped list of UUIDs, for bulk actions. The cap is the point: a bulk
 * endpoint that accepts an unbounded array lets one request do unbounded
 * work, and makes the resulting audit trail one entry for an arbitrary
 * number of decisions.
 */
export function uuidList(fd: FormData, field: string, max: number): string[] {
  const raw = fd.getAll(field).map(String).filter(Boolean);
  if (raw.length === 0) throw new InvalidInput(field, "is required");
  if (raw.length > max) {
    throw new InvalidInput(field, `accepts at most ${max} items at a time`);
  }
  for (const v of raw) {
    if (!UUID_RE.test(v)) throw new InvalidInput(field, "must all be UUIDs");
  }
  return raw;
}

/** An integer within an inclusive range. */
export function intInRange(
  fd: FormData,
  field: string,
  min: number,
  max: number
): number {
  const v = Number(String(fd.get(field) ?? "").trim());
  if (!Number.isInteger(v) || v < min || v > max) {
    throw new InvalidInput(field, `must be a whole number ${min}–${max}`);
  }
  return v;
}

/** An ISO timestamp from a datetime-local input. Empty becomes null. */
export function optTimestamp(fd: FormData, field: string): string | null {
  const v = String(fd.get(field) ?? "").trim();
  if (!v) return null;
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) {
    throw new InvalidInput(field, "must be a valid date and time");
  }
  return d.toISOString();
}
