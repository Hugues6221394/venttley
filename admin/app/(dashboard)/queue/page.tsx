import Link from "next/link";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { canAccess } from "@/lib/roles";
import { getRenderStaff } from "@/lib/supabase/server";
import { getSupportCases } from "@/lib/governance";
import { PageHeader } from "@/components/ui/page-header";
import { Badge, type Tone } from "@/components/ui/badge";
import { Tabs } from "@/components/ui/tabs";
import { EmptyState } from "@/components/ui/empty-state";
import { ChevronRight, CheckCircle2 } from "@/components/ui/icons";
import {
  QUEUE_KINDS, ageLabel, dueLabel, filterWork, fromAppeals, fromCases, fromSupport, fromVerification,
  isMine, parseKind, parseView, rowActions, sortWork,
  type AppealSource, type CaseSource, type QueueKind, type QueuePriority, type QueueView, type VerificationSource, type WorkItem,
} from "@/lib/work-queue";
import { assignSupportItem, claimWorkItem, releaseWorkItem } from "@/lib/work-queue-actions";

export const dynamic = "force-dynamic";

const PRIORITY_TONE: Record<QueuePriority, Tone> = { critical: "danger", high: "warn", normal: "neutral", low: "neutral" };

const RESULTS: Record<string, { tone: "ok" | "warn" | "danger"; text: string }> = {
  claimed: { tone: "ok", text: "Claimed. It now shows under Mine." },
  released: { tone: "ok", text: "Released back to the queue." },
  assigned: { tone: "ok", text: "Assigned." },
  already_claimed: { tone: "warn", text: "Someone else claimed this first. The list is refreshed." },
  no_longer_open: { tone: "warn", text: "This item is no longer open. The list is refreshed." },
  mfa_required: { tone: "warn", text: "This action needs two-factor verification. Verify, then try again." },
  rate_limited: { tone: "warn", text: "Too many changes in a short time. Wait a minute, then try again." },
  forbidden: { tone: "danger", text: "Your role cannot change this queue." },
  not_found: { tone: "danger", text: "That item no longer exists." },
  invalid_input: { tone: "danger", text: "That change was not valid. Refresh and try again." },
  failed: { tone: "danger", text: "The change could not be confirmed. Refresh to see the current state before retrying." },
};

type Assignee = { staff_id: string; display_name: string | null; username: string | null };

type Source = { kind: QueueKind; items: WorkItem[]; failed: boolean };

async function load(kind: QueueKind, read: () => Promise<WorkItem[]>): Promise<Source> {
  try {
    return { kind, items: await read(), failed: false };
  } catch {
    return { kind, items: [], failed: true };
  }
}

export default async function WorkQueuePage({ searchParams }: {
  searchParams: Promise<{ view?: string; kind?: string; result?: string }>;
}) {
  const staff = await getRenderStaff();
  if (!staff) redirect("/login");
  const params = await searchParams;
  const view = parseView(params.view);
  const kind = parseKind(params.kind);
  const now = Date.now();

  const allowed = (Object.keys(QUEUE_KINDS) as QueueKind[]).filter(k => canAccess(staff.role, QUEUE_KINDS[k].route));
  const readers: Record<QueueKind, () => Promise<WorkItem[]>> = {
    case: async () => fromCases(await rpc<CaseSource[]>("admin_case_queue", { p_status: "unresolved", p_assignee: null, p_limit: 200 }) ?? []),
    appeal: async () => fromAppeals(await rpc<AppealSource[]>("admin_appeal_queue", { p_status: "open", p_limit: 200 }) ?? []),
    verification: async () => fromVerification(await rpc<VerificationSource[]>("admin_verification_queue", { p_status: "all", p_search: null, p_limit: 200 }) ?? []),
    support: async () => {
      const result = await getSupportCases(200);
      if (result.error) throw new Error("support queue unavailable");
      return fromSupport(result.data, now);
    },
  };
  const sources = await Promise.all(allowed.map(k => load(k, readers[k])));
  const everything = sortWork(sources.flatMap(s => s.items));
  const failed = sources.filter(s => s.failed).map(s => QUEUE_KINDS[s.kind].label);
  const rows = filterWork(everything, view, kind, staff);
  const result = params.result && Object.hasOwn(RESULTS, params.result) ? RESULTS[params.result] : null;
  const assignees = rows.some(r => r.kind === "support")
    ? await rpc<Assignee[]>("admin_support_assignees", { p_query: "" }).catch(() => [] as Assignee[])
    : [];

  const scoped = kind === "all" ? everything : everything.filter(i => i.kind === kind);
  const counts = {
    all: scoped.length,
    mine: scoped.filter(i => isMine(i, staff)).length,
    unassigned: scoped.filter(i => !i.assignee && !i.assigneeId).length,
    overdue: scoped.filter(i => i.overdue).length,
  };
  const kindHref = (k: QueueKind | "all") => {
    const sp = new URLSearchParams();
    if (view !== "all") sp.set("view", view);
    if (k !== "all") sp.set("kind", k);
    const qs = sp.toString();
    return qs ? `/queue?${qs}` : "/queue";
  };

  return (
    <div className="work-queue">
      <PageHeader
        eyebrow="Daily work"
        title="Work queue"
        subtitle="Everything waiting on staff, in one list. Overdue items come first, then the most severe, then the oldest. Claim an item to take it on, or open it to decide."
      />

      <section className="operator-metrics member-metrics work-queue-metrics" aria-label="Queue summary">
        <Metric label="Open items" value={counts.all} />
        <Metric label="Overdue" value={counts.overdue} alert={counts.overdue > 0} />
        <Metric label="Unassigned" value={counts.unassigned} />
        <Metric label="Assigned to me" value={counts.mine} />
      </section>

      {result && (
        <p role="status" className={`member-notice is-${result.tone}`}>{result.text}</p>
      )}

      {failed.length > 0 && (
        <p role="status" className="member-notice is-warn">
          Could not load: {failed.join(", ")}. The list below is missing those items; open that queue directly.
        </p>
      )}

      <div className="work-queue-controls">
        <Tabs
          basePath="/queue"
          paramKey="view"
          active={view}
          extraParams={{ kind: kind === "all" ? undefined : kind }}
          tabs={[
            { key: "all", label: "All open", count: counts.all },
            { key: "mine", label: "Mine", count: counts.mine },
            { key: "unassigned", label: "Unassigned", count: counts.unassigned },
            { key: "overdue", label: "Overdue", count: counts.overdue, tone: counts.overdue ? "danger" : "neutral" },
          ]}
        />
        {allowed.length > 1 && (
          <nav className="segmented" aria-label="Queue type">
            <Link href={kindHref("all")} aria-current={kind === "all" ? "page" : undefined}>All types</Link>
            {allowed.map(k => (
              <Link key={k} href={kindHref(k)} aria-current={kind === k ? "page" : undefined}>
                {QUEUE_KINDS[k].label}
              </Link>
            ))}
          </nav>
        )}
      </div>

      {rows.length === 0 ? (
        <div className="surface">
          <EmptyState
            icon={<CheckCircle2 size={28} />}
            title={view === "all" ? "Nothing is waiting." : "Nothing matches this view."}
            hint={view === "all" ? "New reports, appeals, verification requests and support cases appear here as they arrive." : "Switch to All open to see everything waiting."}
          />
        </div>
      ) : (
        <div className="surface overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm work-queue-table">
              <thead>
                <tr>
                  <th className="t-th">Type</th>
                  <th className="t-th">Item</th>
                  <th className="t-th">Priority</th>
                  <th className="t-th">Status</th>
                  <th className="t-th">Assignee</th>
                  <th className="t-th text-right">Age</th>
                  <th className="t-th text-right">Due</th>
                  <th className="t-th"><span className="sr-only">Open</span></th>
                </tr>
              </thead>
              <tbody>
                {rows.map(item => (
                  <tr key={`${item.kind}-${item.id}`} className={`t-row${item.overdue ? " is-overdue" : ""}`}>
                    <td className="t-td"><span className={`queue-kind is-${item.kind}`}>{QUEUE_KINDS[item.kind].label}</span></td>
                    <td className="t-td">
                      <span className="queue-title">{item.title}</span>
                      {item.member && <span className="queue-member">@{item.member}</span>}
                    </td>
                    <td className="t-td"><Badge tone={PRIORITY_TONE[item.priority]}>{item.priority}</Badge></td>
                    <td className="t-td text-ink-muted capitalize">{item.status}</td>
                    <td className="t-td">{item.assignee ? (isMine(item, staff) ? <strong>You</strong> : `@${item.assignee}`) : <span className="text-ink-muted">Unassigned</span>}</td>
                    <td className="t-td text-right tabular text-ink-muted">{ageLabel(item.openedAt, now)}</td>
                    <td className={`t-td text-right tabular ${item.overdue ? "text-danger font-semibold" : "text-ink-muted"}`}>{dueLabel(item.dueAt, now)}</td>
                    <td className="t-td">
                      <RowActions item={item} me={staff} view={view} kind={kind} assignees={assignees} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <p className="text-xs text-ink-muted">
        Shows up to 200 open items per queue{allowed.length < 4 ? ", limited to the queues your role can work" : ""}. Claims and assignments are checked and audit-logged like they are in each queue; decisions are made on the item itself.
      </p>
    </div>
  );
}

function RowActions({ item, me, view, kind, assignees }: {
  item: WorkItem; me: { userId: string; pseudonym: string }; view: QueueView; kind: QueueKind | "all"; assignees: Assignee[];
}) {
  const can = rowActions(item, me);
  const hidden = <>
    <input type="hidden" name="item_kind" value={item.kind} />
    <input type="hidden" name="id" value={item.id} />
    <input type="hidden" name="status" value={item.rawStatus} />
    <input type="hidden" name="priority" value={item.priority} />
    <input type="hidden" name="view" value={view} />
    <input type="hidden" name="kind_filter" value={kind} />
  </>;
  const others = assignees.filter(a => a.staff_id !== item.assigneeId);
  return (
    <div className="queue-actions">
      {can.claim && <form action={claimWorkItem}>{hidden}<button type="submit" className="btn-secondary text-xs">Claim</button></form>}
      {can.release && <form action={releaseWorkItem}>{hidden}<button type="submit" className="btn-ghost text-xs">Release</button></form>}
      {can.assign && others.length > 0 && (
        <details className="queue-assign">
          <summary className="btn-ghost text-xs">Assign</summary>
          <form action={assignSupportItem}>
            {hidden}
            <select name="assignee_id" className="select" aria-label="Assign to" required defaultValue="">
              <option value="" disabled>Choose a teammate</option>
              {others.map(a => <option key={a.staff_id} value={a.staff_id}>{a.display_name || a.username || "Staff member"}</option>)}
            </select>
            <button type="submit" className="btn-primary text-xs">Assign</button>
          </form>
        </details>
      )}
      <Link href={item.href} prefetch={false} className="btn-ghost text-xs">Open <ChevronRight size={13} /></Link>
    </div>
  );
}

function Metric({ label, value, alert = false }: { label: string; value: number; alert?: boolean }) {
  return (
    <div className={`operator-metric${alert ? " is-alert" : ""}`}>
      <h3>{label}</h3>
      <div className="operator-metric-value">
        <strong className={value === 0 ? "is-zero" : ""}>{value.toLocaleString()}</strong>
      </div>
    </div>
  );
}
