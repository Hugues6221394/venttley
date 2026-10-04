// Shared metadata contracts. No authored content or browser persistence.
export const inboxFilters = ["unread", "assigned", "urgent", "all"] as const;
export const inboxCategories = ["all", "support", "legal", "moderation", "jobs", "reports", "incidents", "governance"] as const;
export const inboxSeverities = ["all", "info", "warning", "critical"] as const;
export type StaffInboxFilter = typeof inboxFilters[number];
export type InboxCategory = typeof inboxCategories[number];
export type InboxSeverity = typeof inboxSeverities[number];
export type StaffInboxKind = "support_assigned" | "support_sla_breached" | "legal_review_requested" | "moderation_assigned" | "moderation_review_requested" | "job_push_attention" | "job_email_attention" | "job_media_attention" | "impact_report_ready" | "incident_changed" | "incident_overdue" | "access_review_assigned" | "access_review_overdue" | "promotion_review_requested" | "promotion_ready" | "broadcast_review_requested" | "broadcast_ready";
export type StaffInboxItem = {
  event_id: string; kind: StaffInboxKind; severity: Exclude<InboxSeverity, "all">;
  source_id: string; destination: "/support/cases" | "/legal-requests" | `/moderation/cases/${string}` | `/jobs#${string}` | `/impact/reports/${string}` | `/incidents/records/${string}` | `/staff/access-reviews?campaign=${string}` | `/approvals?source=${string}` | `/broadcasts?source=${string}`;
  delivered_at: string; read_at: string | null;
};
export type StaffInboxCursor = { beforeAt: string; beforeId: string };
export type StaffAttention = { enabled: false } | {
  enabled: true; unread_count: number; unread_more: boolean;
  generated_at: string; worker_at: string | null;
  queues: { key: AttentionQueue; count: number; measured_at: string; stale: boolean }[];
};
export const inboxCopy = {
  access_review_assigned: { title: "Staff access review needs attention", description: "You have outstanding work in an access-review campaign. Open the campaign to check your assignments; this notice does not revoke access.", category: "Governance" },
  access_review_overdue: { title: "Staff access review overdue", description: "An open campaign passed its deadline with work still assigned to you. Check the current review scope and decisions.", category: "Governance" },
  promotion_review_requested: { title: "Promotion review requested", description: "A super-admin promotion needs an independent reviewer. Open the exact request to review current authority and expiry.", category: "Governance" },
  promotion_ready: { title: "Promotion approved for execution", description: "Your promotion request was approved. Execution remains a separate MFA-protected action; no role change is implied.", category: "Governance" },
  broadcast_review_requested: { title: "Broadcast review requested", description: "A global broadcast needs independent review. The message is available only in the authorized request, not in this notice.", category: "Governance" },
  broadcast_ready: { title: "Broadcast approved for publication", description: "Your broadcast request was approved. Publication remains a separate action; no publication or device delivery is implied.", category: "Governance" },
  incident_changed: { title: "Incident response updated", description: "An incident assigned to your response team changed. Check its current phase and ownership. No external paging or containment is implied.", category: "Incidents" },
  incident_overdue: { title: "Incident response overdue", description: "An active incident passed its response deadline. Open the incident to check current ownership and next steps.", category: "Incidents" },
  support_assigned: { title: "Support case assigned", description: "A support case was assigned to you. Check its current owner and deadline in the source queue.", category: "Support" },
  support_sla_breached: { title: "Support response overdue", description: "A support case passed its response deadline. Open the source to check its current status.", category: "Support" },
  legal_review_requested: { title: "Legal approval requested", description: "An independent review was requested. Open the legal register to check the current decision state.", category: "Legal" },
  moderation_assigned: { title: "Moderation case assigned", description: "A moderation case was assigned to you. Check its current owner and deadline in the case dossier.", category: "Moderation" },
  moderation_review_requested: { title: "Independent case review requested", description: "A moderation case needs a second reviewer. Open the dossier to check its current state; receiving a notice does not authorize a decision.", category: "Moderation" },
  job_push_attention: { title: "Push delivery needs attention", description: "Dead push deliveries were observed. Open the queue for current outcomes. This notice does not resend any delivery.", category: "Jobs" },
  job_email_attention: { title: "Email delivery needs attention", description: "Failed email deliveries were observed. Open the queue for current outcomes. No addresses or payloads are included here.", category: "Jobs" },
  job_media_attention: { title: "Media scans may be stalled", description: "Unfinished scan leases were more than 15 minutes overdue. Investigate the queue; an expired lease is not a confirmed scan failure.", category: "Jobs" },
  impact_report_ready: { title: "Your report snapshot is ready", description: "Your aggregate report snapshot was generated. Open it to review and export. File download or external delivery is not confirmed.", category: "Reports" },
} as const;
export const isUuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export function sourceHref(item: StaffInboxItem) {
  // Never trust a stored/free-form URL as a navigation destination.
  if (!isUuid(item.source_id)) return null;
  if(item.kind==='access_review_assigned'||item.kind==='access_review_overdue')return `/staff/access-reviews?campaign=${item.source_id}`;
  if(item.kind==='promotion_review_requested'||item.kind==='promotion_ready')return `/approvals?source=${item.source_id}`;
  if(item.kind==='broadcast_review_requested'||item.kind==='broadcast_ready')return `/broadcasts?source=${item.source_id}`;
  if(item.kind==='incident_changed'||item.kind==='incident_overdue')return `/incidents/records/${item.source_id}`;
  if(item.kind==='impact_report_ready')return `/impact/reports/${item.source_id}`;
  if(item.kind==='job_push_attention')return '/jobs#push-failures';
  if(item.kind==='job_email_attention')return '/jobs#email-failures';
  if(item.kind==='job_media_attention')return '/jobs#media-stalled';
  if(item.kind==='moderation_assigned'||item.kind==='moderation_review_requested')return `/moderation/cases/${item.source_id}`;
  const destination = item.kind === "legal_review_requested" ? "/legal-requests" :
    item.kind === "support_assigned" || item.kind === "support_sla_breached" ? "/support/cases" : null;
  return destination ? `${destination}?source=${item.source_id}` : null;
}
export const queueDestinations = {
  incidents: { path: "/incidents", href: "/incidents?filter=active", label: "Active incidents", definition: "Declared through monitoring, excluding resolved and reviewed. Reconciled with the shared attention worker; saturated at 99+. Reading a notice does not resolve an incident." },
  support: { path: "/support/cases", href: "/support/cases?queue=open", label: "Open support cases", definition: "Team cases excluding resolved and closed. Independent of the current page filter or row limit." },
  legal: { path: "/legal-requests", href: "/legal-requests?queue=awaiting_approval", label: "Legal requests awaiting approval", definition: "Team requests awaiting independent approval. Opening the register does not authorize approving your own request." },
  moderation: { path: "/moderation", href: "/moderation?tab=pending", label: "Unresolved moderation reports", definition: "Unresolved reports, not unique cases or people. Several reports can concern the same incident." },
  appeals: { path: "/appeals", href: "/appeals?tab=open", label: "Open appeals", definition: "All open appeals, not just the first 200 shown. Original decision makers still cannot review their own decisions." },
  jobs: { path: "/jobs", href: "/jobs", label: "Jobs needing attention", definition: "Dead push deliveries, failed emails and scan leases overdue by 15 minutes. Saturated at 99+; bounded source snapshots are reconciled each minute." },
} as const;
export type AttentionQueue = keyof typeof queueDestinations;
export const attentionQueueKeys = Object.keys(queueDestinations) as AttentionQueue[];
export function attentionDestination(path: string, data: StaffAttention | null, expanded: boolean) {
  const key = attentionQueueKeys.find(key => queueDestinations[key].path === path);
  return key && (expanded || ((key === 'support' || key === 'legal') && data?.enabled &&
    data.queues.some(queue => queue.key === key))) ? queueDestinations[key].href : path;
}
// Validate server and client boundaries; unknown keys must never become links.
export function parseAttention(value: unknown): StaffAttention | null {
  if (!value || typeof value !== 'object') return null;
  const v = value as Record<string, unknown>;
  if (v.enabled === false) return { enabled: false };
  const timestamp = (v: unknown): v is string => typeof v === 'string' && v.length <= 40 && Number.isFinite(Date.parse(v));
  if (v.enabled !== true || !Number.isSafeInteger(v.unread_count) || (v.unread_count as number) < 0 ||
    (v.unread_count as number) > 99 || typeof v.unread_more !== 'boolean' ||
    !timestamp(v.generated_at) || !(v.worker_at === null || timestamp(v.worker_at)) ||
    !Array.isArray(v.queues) || v.queues.length > attentionQueueKeys.length) return null;
  const seen = new Set<string>();
  for (const q of v.queues) {
    if (!q || !attentionQueueKeys.includes(q.key) || seen.has(q.key) ||
      !Number.isSafeInteger(q.count) || q.count < 0 || !timestamp(q.measured_at) || typeof q.stale !== 'boolean') return null;
    seen.add(q.key);
  }
  return { enabled: true, unread_count: v.unread_count as number, unread_more: v.unread_more,
    generated_at: v.generated_at, worker_at: v.worker_at as string | null,
    queues: v.queues.map(q => ({ key:q.key, count:q.count, measured_at:q.measured_at, stale:q.stale })) };
}
export function staleTimestamp(value: string | null, now = Date.now()) {
  const timestamp = value ? Date.parse(value) : NaN;
  return !Number.isFinite(timestamp) || now - timestamp > 120_000 || timestamp > now + 60_000;
}
export function pollDelay(failures: number) { return Math.min(300_000, 30_000 * 2 ** Math.min(4, Math.max(0, failures))); }
export function parseInboxQuery(params: URLSearchParams) {
  const filter = params.get("filter") ?? "unread", category = params.get("category") ?? "all", severity = params.get("severity") ?? "all";
  const beforeAt = params.get("beforeAt"), beforeId = params.get("beforeId");
  if (!(inboxFilters as readonly string[]).includes(filter) || !(inboxCategories as readonly string[]).includes(category) ||
    !(inboxSeverities as readonly string[]).includes(severity) || !!beforeAt !== !!beforeId ||
    (beforeAt && (beforeAt.length > 40 || !Number.isFinite(Date.parse(beforeAt)) || !isUuid(beforeId)))) return null;
  return { filter: filter as StaffInboxFilter, category: category as InboxCategory, severity: severity as InboxSeverity,
    cursor: beforeAt && beforeId ? { beforeAt, beforeId } : undefined };
}
