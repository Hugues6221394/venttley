import "server-only";
import { createSsrClient } from "@/lib/supabase/server";

// Metadata-only staff API. Never hydrate member-authored source text here.
export type StaffInboxKind = "support_assigned" | "support_sla_breached" | "legal_review_requested";
export type StaffInboxFilter = "all" | "unread" | "urgent" | "assigned";
export type StaffInboxItem = {
  event_id: string;
  kind: StaffInboxKind;
  severity: "info" | "warning" | "critical";
  source_id: string;
  destination: "/support/cases" | "/legal-requests";
  delivered_at: string;
  read_at: string | null;
};
export type StaffInboxCursor = { beforeAt: string; beforeId: string };
export type StaffAttention = { enabled: false } | {
  enabled: true;
  unread_count: number;
  unread_more: boolean;
  generated_at: string;
  worker_at: string | null;
  queues: { key: "support" | "legal"; count: number; measured_at: string; stale: boolean }[];
};

export async function readStaffInbox(filter: StaffInboxFilter = "all", cursor?: StaffInboxCursor) {
  const db = await createSsrClient();
  const { data, error } = await db.rpc("admin_staff_inbox", {
    p_filter: filter, p_limit: 31,
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
  const { data, error } = await db.rpc("admin_staff_attention");
  return error ? { data: null, error: "Attention counts are unavailable." }
    : { data: data as StaffAttention, error: null };
}
