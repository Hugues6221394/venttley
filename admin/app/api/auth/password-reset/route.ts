import { NextRequest, NextResponse } from "next/server";
import { createRateLimiter, ipFrom } from "@/lib/redis";
import { originRejection, sameOrigin } from "@/lib/guard";

/**
 * Password reset for the console.
 *
 * A locked-out super admin had no way back in. The mechanism has existed since
 * 20260917090000 — a code to a *verified* recovery address, then a new
 * password — and the mobile app has used it since. The console never did, so
 * the one account that can suspend members and read the CSAM queue was also
 * the one with no recovery path.
 *
 * Nothing new is invented here. This is a thin proxy to the `password-reset`
 * Edge Function, which is the only caller of begin_password_reset and
 * complete_password_reset — both are service_role-only precisely so the
 * enumeration and rate-limit controls cannot be skipped by calling PostgREST
 * directly. Reimplementing any of that in the console would mean a second,
 * weaker copy of the most dangerous path in the product.
 *
 * What this layer adds is the console's own two controls, which the Edge
 * Function knows nothing about:
 *
 *   * same-origin, because /api/** does not go through Next's Server Action
 *     origin check and these are cookie-less but state-changing;
 *   * a rate limit keyed on IP, tighter than the per-account limit the
 *     database already applies, so one address cannot be used to grind
 *     through many accounts.
 *
 * The response is deliberately identical whether or not an account exists. The
 * Edge Function is careful about this and it would be undone by a console that
 * said "no such user" on the way past.
 */

// Tighter than the database's five-per-account-per-hour: that one stops an
// attacker hammering a single account, this one stops them sweeping many.
const requestLimiter = createRateLimiter("admin_pwreset_request", 5, 900, "deny");
const confirmLimiter = createRateLimiter("admin_pwreset_confirm", 10, 900, "deny");

type Action = "request" | "confirm";

export async function POST(req: NextRequest) {
  if (!sameOrigin(req)) return originRejection();

  let body: { action?: string; identifier?: string; code?: string; new_password?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid request body" }, { status: 400 });
  }

  const action = String(body.action ?? "") as Action;
  if (action !== "request" && action !== "confirm") {
    return NextResponse.json({ ok: false, error: "Unknown action" }, { status: 400 });
  }

  const identifier = String(body.identifier ?? "").trim();
  if (!identifier) {
    return NextResponse.json({ ok: false, error: "Username is required" }, { status: 400 });
  }
  // Bound before anything downstream. The Edge Function hashes and the database
  // compares; neither should be handed an unbounded string.
  if (identifier.length > 100) {
    return NextResponse.json({ ok: false, error: "Username is too long" }, { status: 400 });
  }

  const limiter = action === "request" ? requestLimiter : confirmLimiter;
  const gate = await limiter.limit(ipFrom(req));
  if (!gate.success) {
    if (gate.unavailable) {
      // Fails closed, and says which of the two it is. "Try again later" when
      // the cause is a missing environment variable sends someone to wait out
      // a limit that will never reset.
      return NextResponse.json(
        {
          ok: false,
          error:
            "Password reset is unavailable: rate limiting is not configured on this deployment.",
        },
        { status: 503 },
      );
    }
    return NextResponse.json(
      { ok: false, error: "Too many attempts. Try again shortly." },
      { status: 429 },
    );
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anon) {
    return NextResponse.json(
      { ok: false, error: "Password reset is not configured on this deployment." },
      { status: 503 },
    );
  }

  const payload =
    action === "request"
      ? { action, identifier }
      : {
          action,
          identifier,
          code: String(body.code ?? "").trim(),
          new_password: String(body.new_password ?? ""),
        };

  let upstream: Response;
  try {
    upstream = await fetch(`${url}/functions/v1/password-reset`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: anon, Authorization: `Bearer ${anon}` },
      body: JSON.stringify(payload),
    });
  } catch {
    return NextResponse.json(
      { ok: false, error: "Could not reach the reset service. Try again shortly." },
      { status: 502 },
    );
  }

  const data = (await upstream.json().catch(() => ({}))) as Record<string, unknown>;

  if (action === "request") {
    // Always the same answer. Whether the account exists, whether it has a
    // verified recovery address, whether it is rate limited upstream — none of
    // that is disclosed, because this endpoint is reachable without a session
    // and would otherwise report who has an account here.
    return NextResponse.json({ ok: true });
  }

  if (!upstream.ok) {
    const message =
      typeof data.error === "string" && data.error.length > 0
        ? data.error
        : "That code did not work. Request a new one.";
    return NextResponse.json({ ok: false, error: message }, { status: upstream.status });
  }

  return NextResponse.json({ ok: true });
}
