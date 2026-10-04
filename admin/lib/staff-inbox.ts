import "server-only";
import { createSsrClient } from "@/lib/supabase/server";
import type { StaffInboxFilter, StaffInboxItem, StaffInboxCursor, StaffAttention, InboxCategory, InboxSeverity } from "./inbox-model";
import { parseAttention } from "./inbox-model";

// Metadata-only staff API. Never hydrate member-authored source text here.
export async function readStaffInbox(filter: StaffInboxFilter = "all", cursor?: StaffInboxCursor, category: InboxCategory = "all", severity: InboxSeverity = "all") {
  const db = await createSsrClient();
  const { data, error } = await db.rpc("admin_staff_inbox_page", {
    p_filter: filter, p_category: category, p_severity: severity, p_limit: 31,
    p_before_at: cursor?.beforeAt ?? null, p_before_id: cursor?.beforeId ?? null,
  });
  if (error) return { items: [] as StaffInboxItem[], next: null, error: "The staff inbox could not be loaded. Please retry." };
  const rows = (data ?? []) as StaffInboxItem[];
  const last = rows[29];
  return { items: rows.slice(0, 30), next: rows.length > 30 && last
    ? { beforeAt: last.delivered_at, beforeId: last.event_id } : null, error: null };
}

export async function readStaffAttention(): Promise<{ data: StaffAttention | null; error: string | null }> {
  const db = await createSsrClient();
  const { data, error } = await db.rpc("admin_staff_attention").abortSignal(AbortSignal.timeout(8_000));
  const parsed = parseAttention(data);
  return error || !parsed ? { data: null, error: "Attention counts are unavailable." }
    : { data: parsed, error: null };
}
