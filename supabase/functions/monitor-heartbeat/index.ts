// monitor-heartbeat
//
// Reports background-worker health to the external uptime monitor (Better
// Stack). pg_cron calls this once a minute (migration 20261073090000). It asks
// public.platform_heartbeat_status() whether every active cron job is on time
// and mail is moving, then pings HEARTBEAT_URL when healthy, or
// HEARTBEAT_URL/fail with the failing check names when not.
//
// The monitor alerts when pings stop, so silence is the signal for a dead
// database, scheduler or this function. Only fixed check codes are sent.
//
// Auth: verify_jwt=false plus x-cron-secret: <CRON_SECRET>.
// Env:
//   HEARTBEAT_URL                             — Better Stack heartbeat URL (https)
//   CRON_SECRET                               — shared gate (same as account-purge)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  — admin client (auto-set)

import { adminClient } from "../_shared/supabase.ts";
import { verifyInternalSecret } from "../_shared/internal_auth.ts";

interface HeartbeatStatus {
  healthy: boolean;
  jobs_checked: number;
  problems: string[];
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = verifyInternalSecret(req, {
    envName: "CRON_SECRET",
    headerName: "x-cron-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const target = heartbeatUrl();
  if (!target) return json({ error: "heartbeat_not_configured" }, 503);

  let status: HeartbeatStatus;
  try {
    const { data, error } = await adminClient().rpc("platform_heartbeat_status");
    if (error || !isStatus(data)) throw new Error("status_unavailable");
    status = data;
  } catch {
    status = { healthy: false, jobs_checked: 0, problems: ["status_unavailable"] };
  }

  try {
    const response = status.healthy
      ? await fetch(target, { method: "GET", signal: AbortSignal.timeout(8000) })
      : await fetch(`${target}/fail`, {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: status.problems.join("\n").slice(0, 2000),
        signal: AbortSignal.timeout(8000),
      });
    await response.body?.cancel();
    if (!response.ok) {
      return json({ ...status, reported: false, monitor_status: response.status }, 502);
    }
  } catch {
    return json({ ...status, reported: false }, 502);
  }
  return json({ ...status, reported: true });
});

function heartbeatUrl(): string | null {
  const raw = Deno.env.get("HEARTBEAT_URL")?.trim();
  if (!raw) return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:") return null;
    return url.toString().replace(/\/+$/, "");
  } catch {
    return null;
  }
}

function isStatus(value: unknown): value is HeartbeatStatus {
  const v = value as HeartbeatStatus | null;
  return !!v && typeof v.healthy === "boolean" &&
    typeof v.jobs_checked === "number" &&
    Array.isArray(v.problems) && v.problems.every((p) => typeof p === "string");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
