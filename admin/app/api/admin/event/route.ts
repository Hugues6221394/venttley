import { NextResponse } from "next/server";

import { createSsrClient } from "@/lib/supabase/server";
import {
  createRateLimiter,
  incrementCounter,
  ipFrom,
  isRedisConfigured,
} from "@/lib/redis";
import { originRejection, sameOrigin } from "@/lib/guard";

/**
 * Admin telemetry sink. Two responsibilities:
 *   1. Forward the event to public.record_event() so it lands in
 *      app_events alongside the mobile-client stream.
 *   2. Maintain a cross-instance counter in Redis (e.g. how many
 *      moderation actions happened in the last hour) so the admin
 *      overview can read a live number without scanning Postgres.
 *
 * Rate-limited per IP at 60/min so a runaway client can't drown the
 * record_event RPC.
 */

// Fails closed. Dropping telemetry costs nothing; letting a runaway client
// drown record_event does.
const eventLimiter = createRateLimiter("admin_event", 60, 60, "deny");

type Payload = {
  name?: string;
  severity?: "debug" | "info" | "warn" | "error";
  props?: Record<string, unknown>;
};

const SEVERITIES = ["debug", "info", "warn", "error"] as const;

export async function POST(req: Request) {
  // This route is cookie-authenticated and writes a row. Without an origin
  // check, any page the operator visits could POST here with their session
  // attached — and because the handler calls req.json() regardless of the
  // declared Content-Type, an attacker could send it as a "simple request"
  // (text/plain) that never triggers a CORS preflight.
  if (!sameOrigin(req)) return originRejection();

  const gate = await eventLimiter.limit(ipFrom(req));
  if (!gate.success) {
    return NextResponse.json(
      {
        ok: false,
        error: gate.unavailable ? "Rate limiting unavailable" : "Rate limited",
      },
      { status: gate.unavailable ? 503 : 429 },
    );
  }

  let body: Payload;
  try {
    body = (await req.json()) as Payload;
  } catch {
    return NextResponse.json({ ok: false }, { status: 400 });
  }
  const name = typeof body.name === "string" ? body.name.trim() : "";
  if (!name || name.length > 120) {
    return NextResponse.json(
      { ok: false, error: "name is required, 120 characters or fewer" },
      { status: 400 },
    );
  }
  const severity = body.severity ?? "info";
  if (!SEVERITIES.includes(severity)) {
    return NextResponse.json(
      { ok: false, error: `severity must be one of ${SEVERITIES.join(", ")}` },
      { status: 400 },
    );
  }
  const props = body.props ?? {};
  if (typeof props !== "object" || Array.isArray(props)) {
    return NextResponse.json(
      { ok: false, error: "props must be an object" },
      { status: 400 },
    );
  }

  const supabase = await createSsrClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) {
    return NextResponse.json(
      { ok: false, error: "Not authenticated" },
      { status: 401 },
    );
  }

  const { error } = await supabase.rpc("record_event", {
    p_name: name,
    p_severity: severity,
    p_props: props,
  });
  if (error) {
    return NextResponse.json(
      { ok: false, error: error.message },
      { status: 500 },
    );
  }

  // Hourly counter — Redis is the only place these are aggregated
  // across all admin instances. Expires after 25h so we keep one
  // rolling window without unbounded growth.
  const hourBucket = new Date().toISOString().slice(0, 13); // YYYY-MM-DDTHH
  const counter = await incrementCounter(
    `event:${name}`,
    hourBucket,
    25 * 3600,
  );

  return NextResponse.json({
    ok: true,
    redisConfigured: isRedisConfigured,
    counter,
  });
}
