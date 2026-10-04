import { createSsrClient, getRenderStaff } from "@/lib/supabase/server";
import { readStaffAttention, readStaffInbox } from "@/lib/staff-inbox";
import { parseInboxQuery, isUuid } from "@/lib/inbox-model";
import { sameOrigin } from "@/lib/guard";
import { hasModernShell } from "@/lib/shell-rollout";

export const dynamic = "force-dynamic";
const reply = (data: unknown, status = 200) => Response.json(data, { status, headers: { "Cache-Control": "private, no-store", "Vary": "Cookie" } });
const unavailable = () => reply({ error: "Notifications are unavailable. Please retry." }, 503);

export async function GET(request: Request) {
  try {
    const staff = await getRenderStaff();
    if (!staff) return reply({ error: "Your staff access must be verified again." }, 403);
    const params = new URL(request.url).searchParams;
    const mode = params.get("mode") ?? "attention";
    if (mode === "attention") {
      const queuesUI = process.env.ADMIN_ATTENTION_UI === "true" && hasModernShell(staff.role, process.env.ADMIN_SHELL_V2, process.env.ADMIN_SHELL_V2_ROLES);
      if (process.env.ADMIN_INBOX_UI !== "true" && !queuesUI) return reply({ enabled: false });
      const result = await readStaffAttention();
      return result.error ? unavailable() : reply(result.data);
    }
    if (process.env.ADMIN_INBOX_UI !== "true") return reply({ enabled: false });
    if (mode !== "items" && mode !== "preferences") return reply({ error: "Invalid request." }, 400);
    // Recheck rollout before returning preferences/list, not just in the layout.
    const attention = await readStaffAttention();
    if (attention.error) return unavailable();
    if (!attention.data?.enabled) return reply({ enabled: false });
    if (mode === "preferences") {
      const db = await createSsrClient();
      const { data, error } = await db.rpc("admin_staff_inbox_preferences");
      return error ? unavailable() : reply({ assignment_notifications: data });
    }
    const query = parseInboxQuery(params);
    if (!query) return reply({ error: "Invalid inbox filters or cursor." }, 400);
    if(query.category==="governance"&&process.env.ADMIN_GOVERNANCE_NOTICES_UI!=="true")return reply({error:"Governance notification filter is not enabled."},409);
    const result = await readStaffInbox(query.filter, query.cursor, query.category, query.severity);
    return result.error ? unavailable() : reply({ enabled: true, items: result.items, next: result.next });
  } catch { return unavailable(); }
}

export async function POST(request: Request) {
  if (!sameOrigin(request)) return reply({ error: "Cross-origin request rejected." }, 403);
  try {
    if (!(await getRenderStaff())) return reply({ error: "Your staff access must be verified again." }, 403);
    if (process.env.ADMIN_INBOX_UI !== "true") return reply({ error: "Inbox interface is disabled." }, 409);
    if (!request.headers.get("content-type")?.startsWith("application/json")) return reply({ error: "JSON required." }, 415);
    // Bound the streamed body even when Content-Length is absent or forged.
    const reader = request.body?.getReader();
    if (!reader) return reply({ error: "Invalid request." }, 400);
    const chunks: Uint8Array[] = []; let size = 0;
    while (true) { const { done, value } = await reader.read(); if (done) break; size += value.byteLength;
      if (size > 1024) { await reader.cancel(); return reply({ error: "Request too large." }, 413); } chunks.push(value); }
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const attention = await readStaffAttention();
    if (attention.error) return unavailable();
    if (!attention.data?.enabled) return reply({ error: "Inbox is not enabled for this account." }, 409);
    const db = await createSsrClient();
    if (body?.action === "read" && isUuid(body.eventId) && typeof body.read === "boolean") {
      const { error } = await db.rpc("admin_staff_inbox_set_read", { p_events: [body.eventId], p_read: body.read });
      return error ? unavailable() : reply({ ok: true }); // Never reveal whether an arbitrary event exists.
    }
    if (body?.action === "preferences" && typeof body.assignmentNotifications === "boolean") {
      const { data, error } = await db.rpc("admin_staff_inbox_preferences", { p_assignment_notifications: body.assignmentNotifications });
      return error ? unavailable() : reply({ ok: true, assignment_notifications: data });
    }
    return reply({ error: "Invalid request." }, 400);
  } catch (error) { return error instanceof SyntaxError ? reply({ error: "Invalid JSON." }, 400) : unavailable(); }
}
