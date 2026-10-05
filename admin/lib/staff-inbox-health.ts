import { createSsrClient } from "./supabase/server";
import type { InboxRolloutHealth } from "./staff-inbox-rollout";

export async function loadInboxRollout(): Promise<InboxRolloutHealth | null> {
  try {
    // admin_staff_inbox_health authorizes auth.uid(); a service-role call has none.
    const db = await createSsrClient();
    const { data, error } = await db.rpc("admin_staff_inbox_health");
    if (error || !data || typeof data !== "object") return null;
    const h = data as Record<string, unknown>;
    if (typeof h.enabled !== "boolean" || !Array.isArray(h.audience_roles)) return null;
    return {
      enabled: h.enabled,
      audience_roles: h.audience_roles.filter((r): r is string => typeof r === "string"),
      worker_at: typeof h.worker_at === "string" ? h.worker_at : null,
      worker_stale: h.worker_stale === true,
      pending: Number(h.pending) || 0,
    };
  } catch {
    return null;
  }
}
