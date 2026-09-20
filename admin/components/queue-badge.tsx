import { createAdminClient, createSsrClient, getRenderStaff } from "@/lib/supabase/server";
import { canAccess } from "@/lib/roles";

export type QueueBadgePath = "/moderation" | "/appeals" | "/safety";

/** Server-only queue reads stream independently from the authorized shell.
 * These are queue counts, never personal unread-notification counts. The
 * maintained attention projection will replace these reads in the inbox phase.
 */
export async function QueueBadge({ path }: { path: QueueBadgePath }) {
  const staff = await getRenderStaff();
  if (!staff || !canAccess(staff.role, path)) return null;
  try {
    let count: number | null;
    if (path === "/safety") {
      const db = await createSsrClient();
      const result = await db.rpc("admin_safety_open_count");
      count = result.error || typeof result.data !== "number" ? null : result.data;
    } else {
      const db = await createAdminClient();
      const result = path === "/moderation"
        ? await db.from("reports").select("report_id", { count: "exact", head: true }).eq("is_resolved", false)
        : await db.from("moderation_appeals").select("appeal_id", { count: "exact", head: true }).eq("status", "open");
      count = result.error ? null : result.count;
    }
    if (count === null) return <QueueBadgeUnavailable />;
    if (count === 0) return null;
    return <span className="pill bg-danger/15 text-danger" aria-label={`${count} open items`} title="Open items at page load; refresh to update">{count > 99 ? "99+" : count}</span>;
  } catch {
    return <QueueBadgeUnavailable />;
  }
}

export function QueueBadgeUnavailable() {
  return <span className="text-xs text-ink-muted" aria-label="Queue count unavailable" title="Queue count unavailable; open the queue to retry">—</span>;
}
