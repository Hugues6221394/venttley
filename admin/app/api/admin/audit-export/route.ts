import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";

/**
 * CSV export of the audit log. Gated by the same role check the dashboard
 * uses; reads through the admin client only after the caller is confirmed
 * to be staff. Honours the same filter querystring as /audit.
 */
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
  if (from) q = q.gte("created_at", new Date(from).toISOString());
  if (to) q = q.lte("created_at", new Date(to + "T23:59:59").toISOString());

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
