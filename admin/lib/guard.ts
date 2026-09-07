import { headers } from "next/headers";
import { createRateLimiter, ipFrom } from "./redis";
import { createSsrClient } from "./supabase/server";

/**
 * Origin checking and rate limiting for the two request shapes this app
 * exposes: Server Actions and app/api/** route handlers.
 *
 * Next.js already does a same-origin check for Server Actions — it compares
 * the Origin header against Host inside its action handler and rejects a
 * mismatch outright. That protection does NOT extend to route handlers:
 * app/api/** never passes through that code path, so every route there is
 * reachable by any page on the internet with the admin's cookies attached.
 * /api/admin/event and /api/auth/logout are both state-changing, cookie-
 * authenticated POSTs, which is the exact shape of a CSRF bug.
 */

/**
 * Whether the request came from this deployment's own origin.
 *
 * Requires Origin (or, failing that, Referer) to be present AND to match the
 * host we were reached on. Note this is deliberately stricter than Next's
 * built-in Server Action check, which lets a request through when Origin is
 * absent entirely. That is a defensible default for Next — a request with no
 * Origin was not sent by a browser doing a cross-site form post — but these
 * routes have no reason to accept one, and "absent" is the easiest header
 * state for an attacker to arrange.
 *
 * X-Forwarded-Host is preferred over Host because the console is expected to
 * run behind a proxy (see the README's deployment requirements, which also
 * require that proxy to strip attacker-supplied forwarding headers at the
 * edge — without that, this comparison is only as trustworthy as the header).
 */
export function sameOrigin(req: Request): boolean {
  const h = req.headers;
  const host = h.get("x-forwarded-host") ?? h.get("host");
  if (!host) return false;

  const candidate = h.get("origin") ?? h.get("referer");
  if (!candidate) return false;

  try {
    return new URL(candidate).host === host;
  } catch {
    return false;
  }
}

/** 403 when the request did not come from our own origin. */
export function originRejection(): Response {
  return Response.json(
    { ok: false, error: "Cross-origin request rejected" },
    { status: 403 }
  );
}

/**
 * Rate limiting for privileged Server Actions.
 *
 * Keyed on the acting staff member rather than the IP the API routes use.
 * A shared office IP would otherwise let one operator's bulk run throttle
 * everyone else, and an operator moving between networks would reset their
 * own budget. Falls back to the IP when there is no session, which should
 * not happen behind the layout's staff gate but must not throw here.
 *
 * The limits are deliberately generous: this is a backstop against a runaway
 * loop or a scripted mass-action, not a workflow constraint on a moderator
 * working a queue.
 */
// These run loudly rather than closed when Upstash is missing. Refusing them
// would stop a moderator suspending an account or clearing a crisis queue
// because a cache is unconfigured — trading a small abuse risk for a real
// safety harm. The failure is logged on every call instead of hidden.
const actionLimiters = {
  destructive: createRateLimiter("admin_destructive", 20, 60, "allow-loudly"),
  bulk: createRateLimiter("admin_bulk", 10, 60, "allow-loudly"),
} as const;

export async function limitAction(
  kind: keyof typeof actionLimiters
): Promise<void> {
  const h = await headers();
  let key: string;
  try {
    const supabase = await createSsrClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    key =
      user?.id ??
      h.get("x-forwarded-for")?.split(",")[0]?.trim() ??
      h.get("x-real-ip") ??
      "unknown";
  } catch {
    key = h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  }

  const gate = await actionLimiters[kind].limit(key);
  if (!gate.success) {
    throw new Error(
      "Rate limit reached for this kind of action. Wait a moment and try again."
    );
  }
}

export { ipFrom };
