import { NextResponse } from "next/server";

import { createSsrClient } from "@/lib/supabase/server";
import {
  createRateLimiter,
  incrementCounter,
  ipFrom,
  isRedisConfigured,
} from "@/lib/redis";

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

const eventLimiter = createRateLimiter("admin_event", 60, 60);

type Payload = {
  name?: string;
  severity?: "debug" | "info" | "warn" | "error";
  props?: Record<string, unknown>;
};

export async function POST(req: Request) {
  const gate = await eventLimiter.limit(ipFrom(req));
  if (!gate.success) {
    return NextResponse.json(
      { ok: false, error: "Rate limited" },
      { status: 429 },
    );
  }

  let body: Payload;
  try {
    body = (await req.json()) as Payload;
  } catch {
    return NextResponse.json({ ok: false }, { status: 400 });
  }
  const name = body.name;
  if (!name) {
    return NextResponse.json(
      { ok: false, error: "name is required" },
      { status: 400 },
    );
  }
  const severity = body.severity ?? "info";
  const props = body.props ?? {};

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
