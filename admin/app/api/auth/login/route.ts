import { NextResponse } from "next/server";

import { createSsrClient } from "@/lib/supabase/server";
import { syntheticEmail } from "@/lib/supabase/client";
import { createRateLimiter, ipFrom } from "@/lib/redis";
import { originRejection, sameOrigin } from "@/lib/guard";

/**
 * Server-side login proxy. Rate-limited by IP via Upstash Redis so
 * brute-force attempts are throttled across every Vercel instance,
 * not per-process. Cookies are set on the response automatically by
 * the SSR helper.
 *
 * When UPSTASH_REDIS_REST_URL is unset the limiter is permissive in
 * development and refuses outright in production — see UnconfiguredPolicy in
 * lib/redis.ts. It used to no-op everywhere, which meant a production deploy
 * missing two env vars accepted unlimited password attempts silently.
 */

// Fails closed: an admin console with unlimited password attempts is worse
// than one that refuses to sign anybody in until Upstash is configured.
const loginLimiter = createRateLimiter("login", 5, 60, "deny");

export async function POST(req: Request) {
  // Not a CSRF target in the usual sense — there is no session to ride yet —
  // but a cross-origin page posting here can log an operator into an account
  // the attacker controls, so that anything they then do in the console is
  // recorded against, and visible to, the attacker. Cheap to close.
  if (!sameOrigin(req)) return originRejection();

  const ip = ipFrom(req);
  const gate = await loginLimiter.limit(ip);
  if (!gate.success) {
    // 503, not 429, when the control itself cannot run: "try again in a
    // minute" would send an operator away to wait for something that will
    // never clear on its own. The message stays generic either way — telling
    // an anonymous caller which control is missing is telling an attacker
    // exactly when the console is weakest. The detail is in the server log
    // and on /system.
    if (gate.unavailable) {
      return NextResponse.json(
        { ok: false, error: "Sign-in is temporarily unavailable." },
        { status: 503 },
      );
    }
    return NextResponse.json(
      {
        ok: false,
        error: "Too many attempts. Try again in a minute.",
        retryAfter: gate.reset,
      },
      { status: 429 },
    );
  }

  let payload: { username?: string; password?: string };
  try {
    payload = await req.json();
  } catch {
    return NextResponse.json(
      { ok: false, error: "Invalid request body" },
      { status: 400 },
    );
  }
  const { username, password } = payload;
  if (!username || !password) {
    return NextResponse.json(
      { ok: false, error: "Username and password are required" },
      { status: 400 },
    );
  }
  // Bound both before they reach GoTrue. bcrypt hashes the whole input, so an
  // unbounded password is CPU the rate limiter cannot fully price in.
  if (username.length > 100 || password.length > 200) {
    return NextResponse.json(
      { ok: false, error: "Username or password is too long" },
      { status: 400 },
    );
  }

  const supabase = await createSsrClient();
  const { data, error } = await supabase.auth.signInWithPassword({
    email: syntheticEmail(username),
    password,
  });
  if (error || !data.user) {
    return NextResponse.json(
      { ok: false, error: error?.message ?? "Login failed" },
      { status: 401 },
    );
  }

  // Session audit: record the successful admin sign-in. Same client instance,
  // so it now carries the fresh session and auth.uid() resolves to this admin.
  // admin_log() is staff-gated; a non-staff sign-in simply fails the log
  // (caught) and gets bounced by middleware anyway.
  try {
    await supabase.rpc("admin_log", {
      p_action: "admin.login",
      p_target_type: "session",
      p_target_id: null,
      p_target_label: username,
      p_before: null,
      p_after: null,
      p_reason: null,
      p_metadata: { ip },
    });
  } catch {
    // Never block login on an audit failure.
  }

  return NextResponse.json({ ok: true });
}
