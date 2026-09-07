import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { createRateLimiter, ipFrom } from "@/lib/redis";

/**
 * CSV export of the audit log. Gated by the same role check the dashboard
 * uses; reads through the admin client only after the caller is confirmed
 * to be staff. Honours the same filter querystring as /audit.
 *
 * No origin check here, unlike the POST routes: this is a read-only GET
 * reached by clicking a download link, so a top-level navigation (or a
 * pasted URL, or a bookmark) legitimately arrives with no Origin and
 * sometimes no Referer. Requiring one would break the feature to defend
 * against a cross-origin read that the same-origin policy already prevents —
 * an attacker's page can cause this request but cannot read the response.
 * It is rate-limited instead, because each call is a 5000-row export of the
 * most sensitive table in the system.
 */
// Fails closed: each call exports 5000 rows of the audit log, so an
// unthrottled export endpoint is an exfiltration path, not a convenience.
const exportLimiter = createRateLimiter("audit_export", 10, 300, "deny");

export async function GET(req: NextRequest) {
  const ssr = await createSsrClient();
  const {
    data: { user },
  } = await ssr.auth.getUser();
  if (!user) return new NextResponse("Unauthorized", { status: 401 });

  const { data: row } = await ssr
    .from("users")
    .select("user_role")
    .eq("user_id", user.id)
    .maybeSingle();
  if (!row || !["super_admin", "admin", "read_only_auditor"].includes(row.user_role)) {
    return new NextResponse("Forbidden", { status: 403 });
  }

  const gate = await exportLimiter.limit(user.id || ipFrom(req));
  if (!gate.success) {
    if (gate.unavailable) {
      return new NextResponse(
        "Export is unavailable: rate limiting is not configured on this deployment.",
        { status: 503 }
      );
    }
    return new NextResponse(
      "Too many exports. Wait a few minutes and try again.",
      { status: 429 }
    );
  }

  const sp = req.nextUrl.searchParams;
  const db = await createAdminClient();
  let q = db
    .from("audit_log")
    .select(
      "audit_id, created_at, actor_pseudonym, actor_role, action, target_type, target_id, target_label, reason, ip"
    )
    .order("created_at", { ascending: false })
    .limit(5000);
  const actor = sp.get("actor");
  const action = sp.get("action");
  const targetType = sp.get("target_type");
  const targetId = sp.get("target_id");
  const from = sp.get("from");
  const to = sp.get("to");
  if (actor) q = q.ilike("actor_pseudonym", `%${actor}%`);
  if (action) q = q.ilike("action", `${action}%`);
  if (targetType) q = q.eq("target_type", targetType);
  if (targetId) q = q.eq("target_id", targetId);
  // new Date("nonsense").toISOString() throws RangeError, so an unparseable
  // ?from= was a 500 rather than a 400.
  if (from) {
    const d = new Date(from);
    if (Number.isNaN(d.getTime())) {
      return new NextResponse("Invalid 'from' date", { status: 400 });
    }
    q = q.gte("created_at", d.toISOString());
  }
  if (to) {
    const d = new Date(to + "T23:59:59");
    if (Number.isNaN(d.getTime())) {
      return new NextResponse("Invalid 'to' date", { status: 400 });
    }
    q = q.lte("created_at", d.toISOString());
  }

  const { data, error } = await q;
  if (error) return new NextResponse(error.message, { status: 500 });

  const headers = [
    "audit_id",
    "created_at",
    "actor_pseudonym",
    "actor_role",
    "action",
    "target_type",
    "target_id",
    "target_label",
    "reason",
    "ip",
  ];
  const rows = (data ?? []).map((r) =>
    headers
      .map((h) => csvEscape(String((r as Record<string, unknown>)[h] ?? "")))
      .join(",")
  );
  const csv = [headers.join(","), ...rows].join("\n");
  const stamp = new Date().toISOString().slice(0, 10);
  return new NextResponse(csv, {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="venttly-audit-${stamp}.csv"`,
    },
  });
}

function csvEscape(v: string): string {
  if (/[",\n]/.test(v)) {
    return `"${v.replace(/"/g, '""')}"`;
  }
  return v;
}
