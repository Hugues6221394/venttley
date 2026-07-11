import { NextResponse } from "next/server";

import { createSsrClient } from "@/lib/supabase/server";
import { syntheticEmail } from "@/lib/supabase/client";
import { createRateLimiter, ipFrom } from "@/lib/redis";

/**
 * Server-side login proxy. Rate-limited by IP via Upstash Redis so
 * brute-force attempts are throttled across every Vercel instance,
 * not per-process. Cookies are set on the response automatically by
 * the SSR helper.
 *
 * When UPSTASH_REDIS_REST_URL is unset the limiter no-ops and the
 * route degrades to "Supabase auth only" — fine for dev.
 */

const loginLimiter = createRateLimiter("login", 5, 60);

export async function POST(req: Request) {
  const ip = ipFrom(req);
  const gate = await loginLimiter.limit(ip);
  if (!gate.success) {
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
