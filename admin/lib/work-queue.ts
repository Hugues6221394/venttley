// One list of open work across the four review queues. Pure: no database,
// no request state, so ordering and filtering can be checked in isolation.

export type QueueKind = "case" | "appeal" | "verification" | "support";
export type QueuePriority = "critical" | "high" | "normal" | "low";
export type QueueView = "all" | "mine" | "unassigned" | "overdue";

export type WorkItem = {
  kind: QueueKind;
  id: string;
  title: string;
  member: string | null;
  priority: QueuePriority;
  status: string;
  assigneeId: string | null;
  assignee: string | null;
  openedAt: string;
  dueAt: string | null;
  overdue: boolean;
  href: string;
};

export type CaseSource = {
  case_id: string; target_type: string; subject_pseudonym: string | null; status: string; severity: string;
  assignee_id: string | null; assignee_pseudonym: string | null; report_count: number;
  sla_due_at: string | null; sla_breached: boolean; opened_at: string;
};
export type AppealSource = {
  appeal_id: string; subject_kind: string; appellant_pseudonym: string | null; status: string;
  original_decision: string | null; reviewable_by_me: boolean; created_at: string;
};
export type VerificationSource = {
  request_id: string; pseudonym: string | null; status: string; category: string | null;
  claimed_by_pseudonym: string | null; created_at: string;
};
export type SupportSource = {
  support_case_id: string; category: string; priority: string; status: string;
  assignee_id: string | null; assignee_name: string | null; sla_due_at: string | null; created_at: string;
};

export const QUEUE_KINDS: Record<QueueKind, { label: string; route: string }> = {
  case: { label: "Moderation case", route: "/moderation" },
  appeal: { label: "Appeal", route: "/appeals" },
  verification: { label: "Verification", route: "/verification" },
  support: { label: "Support", route: "/support/cases" },
};

const OPEN_VERIFICATION = new Set(["pending", "under_review", "more_info"]);
const CLOSED_SUPPORT = new Set(["resolved", "closed"]);
const words = (value: string | null | undefined) => (value ?? "").replaceAll("_", " ");

function casePriority(severity: string): QueuePriority {
  if (severity === "critical") return "critical";
  if (severity === "high" || severity === "elevated") return "high";
  return severity === "low" ? "low" : "normal";
}

function supportPriority(priority: string): QueuePriority {
  return (["critical", "high", "normal", "low"] as const).find(p => p === priority) ?? "normal";
}

export function fromCases(rows: CaseSource[]): WorkItem[] {
  return rows.filter(r => r.status !== "resolved").map(r => ({
    kind: "case", id: r.case_id,
    title: `${words(r.target_type)} · ${r.report_count} ${r.report_count === 1 ? "report" : "reports"}`,
    member: r.subject_pseudonym, priority: casePriority(r.severity), status: words(r.status),
    assigneeId: r.assignee_id, assignee: r.assignee_pseudonym,
    openedAt: r.opened_at, dueAt: r.sla_due_at, overdue: !!r.sla_breached,
    href: "/moderation?tab=cases",
  }));
}

export function fromAppeals(rows: AppealSource[]): WorkItem[] {
  return rows.filter(r => r.status === "open").map(r => ({
    kind: "appeal", id: r.appeal_id,
    title: r.original_decision ? `Appeal of ${words(r.original_decision)}` : `Appeal · ${words(r.subject_kind)}`,
    member: r.appellant_pseudonym, priority: "normal", status: r.reviewable_by_me ? "open" : "open · another reviewer",
    assigneeId: null, assignee: null, openedAt: r.created_at, dueAt: null, overdue: false,
    href: "/appeals",
  }));
}

export function fromVerification(rows: VerificationSource[]): WorkItem[] {
  return rows.filter(r => OPEN_VERIFICATION.has(r.status)).map(r => ({
    kind: "verification", id: r.request_id,
    title: r.category ? `${words(r.category)} application` : "Verification request",
    member: r.pseudonym, priority: "low", status: words(r.status),
    assigneeId: null, assignee: r.claimed_by_pseudonym, openedAt: r.created_at, dueAt: null, overdue: false,
    href: r.pseudonym ? `/verification?q=${encodeURIComponent(r.pseudonym)}` : "/verification",
  }));
}

export function fromSupport(rows: SupportSource[], now: number): WorkItem[] {
  return rows.filter(r => !CLOSED_SUPPORT.has(r.status)).map(r => ({
    kind: "support", id: r.support_case_id,
    title: words(r.category), member: null,
    priority: supportPriority(r.priority), status: words(r.status),
    assigneeId: r.assignee_id, assignee: r.assignee_name,
    openedAt: r.created_at, dueAt: r.sla_due_at,
    overdue: !!r.sla_due_at && Date.parse(r.sla_due_at) < now,
    href: "/support/cases",
  }));
}

const RANK: Record<QueuePriority, number> = { critical: 0, high: 1, normal: 2, low: 3 };

// Overdue first, then priority, then whatever is due soonest, then oldest.
export function sortWork(items: WorkItem[]): WorkItem[] {
  const due = (item: WorkItem) => item.dueAt ? Date.parse(item.dueAt) : Number.POSITIVE_INFINITY;
  return [...items].sort((a, b) =>
    Number(b.overdue) - Number(a.overdue) ||
    RANK[a.priority] - RANK[b.priority] ||
    due(a) - due(b) ||
    Date.parse(a.openedAt) - Date.parse(b.openedAt));
}

export function isMine(item: WorkItem, me: { userId: string; pseudonym: string }) {
  return item.assigneeId ? item.assigneeId === me.userId : item.assignee === me.pseudonym;
}

export function filterWork(items: WorkItem[], view: QueueView, kind: QueueKind | "all",
  me: { userId: string; pseudonym: string }): WorkItem[] {
  return items.filter(item =>
    (kind === "all" || item.kind === kind) &&
    (view === "all" ||
      (view === "mine" && isMine(item, me)) ||
      (view === "unassigned" && !item.assignee && !item.assigneeId) ||
      (view === "overdue" && item.overdue)));
}

export function parseView(value: string | undefined): QueueView {
  return value === "mine" || value === "unassigned" || value === "overdue" ? value : "all";
}

export function parseKind(value: string | undefined): QueueKind | "all" {
  return value && Object.hasOwn(QUEUE_KINDS, value) ? value as QueueKind : "all";
}

export function ageLabel(iso: string, now: number): string {
  const minutes = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h`;
  return `${Math.round(hours / 24)}d`;
}

export function dueLabel(iso: string | null, now: number): string {
  if (!iso) return "—";
  const minutes = Math.round((Date.parse(iso) - now) / 60_000);
  const span = ageLabel(new Date(now - Math.abs(minutes) * 60_000).toISOString(), now);
  return minutes < 0 ? `${span} late` : `in ${span}`;
}
