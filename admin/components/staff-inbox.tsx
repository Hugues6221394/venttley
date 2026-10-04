"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { Bell, RefreshCw, X, ArrowRight, Mail, Settings2 } from "lucide-react";
import { containDialogTab } from "@/lib/dialog-focus";
import { inboxCopy, inboxFilters, parseInboxQuery, queueDestinations, sourceHref, staleTimestamp,
  type StaffInboxItem, type StaffInboxCursor, type AttentionQueue } from "@/lib/inbox-model";
import { inboxRequest, useStaffAttention } from "./staff-attention";

const filterLabels = { unread: "Unread", assigned: "Assigned to me", urgent: "Urgent", all: "All" };
const time = (value: string) => new Date(value).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

export function AttentionFreshness() {
  const { available, data, error, stale, loading, refresh } = useStaffAttention();
  return <div className="inbox-freshness">
    <span role="status">{!available ? "Inbox interface is disabled" : error ? "Refresh unavailable · counts unknown" : !data ? "Checking notification availability…" : !data.enabled ? "Pilot not enabled for this account" : stale ? "Delivery or count snapshot is stale" : `Counts checked ${time(data.generated_at)}`}</span>
    {available && <button type="button" className="btn-ghost" onClick={refresh} disabled={loading}><RefreshCw size={14} />{loading ? "Checking…" : "Refresh"}</button>}
  </div>;
}

export function AttentionQueueBadge({ queue }: { queue: AttentionQueue }) {
  const { available, queuesAvailable, data, stale, error } = useStaffAttention();
  if ((!available && !queuesAvailable) || data?.enabled === false) return null;
  const snapshot = data?.enabled ? data.queues.find(item => item.key === queue) : null;
  if (data?.enabled && !snapshot) return null; // Permission removed, not a zero queue.
  if (!snapshot || error || stale || snapshot.stale || staleTimestamp(snapshot.measured_at)) {
    return <span aria-label={`${queueDestinations[queue].label}: count unavailable or stale`} title="Queue count unavailable or stale">—</span>;
  }
  return <span className="inbox-queue-badge" title={`${queueDestinations[queue].label} · measured ${time(snapshot.measured_at)}`}
    aria-label={`${snapshot.count>99?'99+':snapshot.count} ${queueDestinations[queue].label.toLowerCase()}`}>{snapshot.count > 99 ? "99+" : snapshot.count}</span>;
}

export function NotificationBell() {
  const { available, data, stale, error } = useStaffAttention();
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null), wasOpen = useRef(false);
  const pathname = usePathname();
  useEffect(() => { setOpen(false); }, [pathname]);
  useEffect(() => { if (wasOpen.current && !open) trigger.current?.focus(); wasOpen.current = open; }, [open]);
  if (!available) return <button type="button" className="icon-btn" disabled aria-label="Staff inbox is not enabled"><Bell size={16} /></button>;
  const count = error || stale || !data ? "—" : data.enabled ? data.unread_more ? "99+" : String(data.unread_count) : null;
  return <>
    <button ref={trigger} type="button" className="icon-btn inbox-bell" aria-haspopup="dialog" aria-expanded={open}
      aria-label={`Open staff inbox${count === "—" ? "; unread count unavailable or stale" : count ? `; ${count} unread notifications` : "; pilot not enabled"}`}
      onClick={() => setOpen(true)}><Bell size={17} />{count !== null && <span className="inbox-unread-badge" aria-hidden="true">{count}</span>}</button>
    {open && <InboxDrawer onClose={() => setOpen(false)} />}
  </>;
}

function InboxDrawer({ onClose }: { onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { ref.current?.showModal(); }, []);
  return <dialog ref={ref} className="inbox-drawer" aria-labelledby="inbox-drawer-heading"
    onKeyDown={containDialogTab} onCancel={event => { event.preventDefault(); onClose(); }}>
    <header className="inbox-drawer-heading"><div><p className="h-eyebrow">Your workspace</p><h2 id="inbox-drawer-heading">Unread notifications</h2></div>
      <button className="icon-btn" type="button" autoFocus onClick={onClose} aria-label="Close notifications"><X size={18} /></button></header>
    <p className="inbox-note">Personal notices, not the team&apos;s queue. Reading a notice does not resolve its source.</p>
    <AttentionFreshness /><InboxList compact />
    <footer className="inbox-drawer-footer"><Link href="/inbox" prefetch={false} className="btn-primary" onClick={onClose}>View full inbox <ArrowRight size={16} /></Link></footer>
  </dialog>;
}

export default function StaffInbox({governance = false}:{governance?:boolean}) {
  const attention = useStaffAttention();
  const data = attention.data;
  const [preferences, setPreferences] = useState(false);
  return <div className="staff-inbox">
    <div className="inbox-heading"><div><p className="h-eyebrow">Staff inbox</p><h1>Your personal notifications</h1>
      <p>Assignments, overdue responses, and independent approvals. No member-authored content.</p></div>
      <button type="button" className="btn-secondary" aria-expanded={preferences} onClick={() => setPreferences(value => !value)}><Settings2 size={16} />Preferences</button></div>
    {preferences && <InboxPreferences />}
    <div className="inbox-metrics">
      <section className="inbox-metric" aria-label="Personal unread notifications"><Mail size={23} /><div><p>Your unread notifications</p>
        <strong>{data?.enabled && !attention.stale && !attention.error ? data.unread_more ? "99+" : data.unread_count : "—"}</strong><small>Reading never resolves the source</small></div></section>
      <section className="inbox-metric inbox-cadence"><RefreshCw size={23} /><div><p>Refresh cadence</p><strong>30 seconds</strong><small>While visible · backs off on errors · not instant delivery</small></div></section>
    </div>
    <AttentionFreshness />
    {data?.enabled && data.queues.length > 0 && <nav className="inbox-queue-links" aria-label="Team actionable queues">
      <span>Team queues</span>{data.queues.filter(queue => attention.queuesAvailable || queue.key === 'support' || queue.key === 'legal').map(queue => <Link key={queue.key} href={queueDestinations[queue.key].href} prefetch={false}>
        {queueDestinations[queue.key].label} <AttentionQueueBadge queue={queue.key} /><ArrowRight size={14} /></Link>)}
    </nav>}
    <InboxList governance={governance} />
    <p className="inbox-note">Sources are separately enabled: support, legal, moderation, jobs, report snapshots and incidents.{governance&&" Governance notices cover access reviews and promotion/broadcast approvals. These operational notices are not muted by optional assignment preferences."} Delivery is asynchronous; reading never completes the work. File delivery and external paging are not confirmed.</p>
  </div>;
}

function InboxList({ compact = false, governance = false }: { compact?: boolean; governance?:boolean }) {
  const attention = useStaffAttention();
  const params = useSearchParams();
  const parsed = parseInboxQuery(compact ? new URLSearchParams() : new URLSearchParams(params.toString()));
  const filter = parsed?.filter ?? "unread", category = parsed?.category ?? "all", severity = parsed?.severity ?? "all";
  const [cursor, setCursor] = useState<StaffInboxCursor | undefined>();
  const [items, setItems] = useState<StaffInboxItem[]>([]);
  const [next, setNext] = useState<StaffInboxCursor | null>(null);
  const [loading, setLoading] = useState(false), [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<string | null>(null), [notice, setNotice] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);
  const lastFilters = useRef(`${filter}/${category}/${severity}`);
  const enabled = attention.available && attention.data?.enabled === true;
  useEffect(() => {
    const key = `${filter}/${category}/${severity}`;
    if (lastFilters.current !== key) { lastFilters.current = key; setCursor(undefined); setItems([]); setNext(null); }
  }, [filter, category, severity]);
  useEffect(() => {
    if (!enabled) { setItems([]); setNext(null); return; }
    let stopped = false; const controller = new AbortController();
    setLoading(true); setError(null);
    const timeout = setTimeout(() => controller.abort(), 12_000);
    const query = new URLSearchParams({ mode: "items", filter, category, severity, ...(cursor ?? {}) });
    inboxRequest(query, controller.signal).then(result => {
      if (stopped) return;
      if (!result.enabled) { setItems([]); setNext(null); attention.refresh(); return; }
      setItems(result.items); setNext(result.next);
    }).catch(() => { if (!stopped) { setItems([]); setNext(null); setError("Notifications could not be loaded. Your filters are preserved; please retry."); } })
      .finally(() => { clearTimeout(timeout); if (!stopped) setLoading(false); });
    return () => { stopped = true; clearTimeout(timeout); controller.abort(); };
  }, [enabled, attention.revision, attention.refresh, filter, category, severity, cursor, retry]);
  const href = (changes: Record<string, string>) => `/inbox?${new URLSearchParams({ filter, category, severity, ...changes })}`;
  async function mark(item: StaffInboxItem) {
    if (pending) return; setPending(item.event_id); setNotice(null);
    try { await inboxRequest(new URLSearchParams(), AbortSignal.timeout(12_000), { action: "read", eventId: item.event_id, read: !item.read_at });
      setNotice(item.read_at ? "Marked unread. Source status is unchanged." : "Marked read. Source status is unchanged."); attention.refresh(); setRetry(value => value + 1);
    } catch { setNotice("Could not save read state. Please retry; source status is unchanged."); }
    finally { setPending(null); }
  }
  return <section className={`inbox-list ${compact ? "inbox-list-compact" : ""}`} aria-label={compact ? "Recent unread notices" : "Notification list"}>
    {!compact && <div className="inbox-filterbar"><nav className="inbox-tabs" aria-label="Notification views">
      {inboxFilters.map(value => <Link key={value} href={href({ filter: value })} prefetch={false} aria-current={filter === value ? "page" : undefined}>{filterLabels[value]}</Link>)}
    </nav><form action="/inbox" className="inbox-filter-form"><input type="hidden" name="filter" value={filter} />
      <label>Category<select key={`category-${category}`} name="category" defaultValue={category} className="select"><option value="all">All categories</option><option value="support">Support</option><option value="legal">Legal</option><option value="moderation">Moderation</option><option value="jobs">Jobs</option><option value="reports">Reports</option><option value="incidents">Incidents</option>{governance&&<option value="governance">Governance</option>}</select></label>
      <label>Severity<select key={`severity-${severity}`} name="severity" defaultValue={severity} className="select"><option value="all">All severities</option><option value="info">Info</option><option value="warning">Warning</option><option value="critical">Critical</option></select></label>
      <button type="submit" className="btn-secondary">Apply</button></form></div>}
    <div role="status" className="inbox-action-status">{notice}</div>
    {!parsed && <p className="inbox-state" role="alert">Invalid inbox filters. <Link href="/inbox">Reset filters</Link></p>}
    {!attention.available || attention.data?.enabled === false ? <div className="inbox-state"><Bell size={28} /><h3>Inbox pilot is not enabled</h3><p>Continue using the operational queues. No unread count can be inferred from this state.</p></div> :
      attention.error ? <div className="inbox-state" role="alert"><h3>Notifications unavailable</h3><p>{attention.error}</p><button type="button" className="btn-secondary" onClick={attention.refresh}>Retry</button></div> :
      error ? <div className="inbox-state" role="alert"><p>{error}</p><button type="button" className="btn-secondary" onClick={() => setRetry(value => value + 1)}>Retry list</button></div> :
      (loading && items.length === 0) || !attention.data ? <p className="inbox-state" role="status">Loading notifications…</p> :
      items.length === 0 ? <div className="inbox-state"><Mail size={28} /><h3>No notifications in this view</h3><p>This does not mean your team&apos;s queues are clear.</p></div> :
      <ul>{(compact ? items.slice(0, 5) : items).map(item => { const copy = inboxCopy[item.kind], source = sourceHref(item); if (!copy) return null;
        const icon = item.kind === "support_assigned" ? 1 : item.kind === "support_sla_breached" ? 2 : 3;
        return <li key={item.event_id} className="inbox-row" data-read={!!item.read_at}>
          <img className="inbox-row-icon" src={`/design/inbox/viewport-1-a-main-notifications-item-${icon}-icon.png`} width={30} height={30} alt="" />
          <div className="inbox-row-content"><h3>{!item.read_at && <span className="inbox-dot" aria-label="Unread" />}{copy.title}</h3><p>{copy.description}</p>
            <div className="inbox-row-meta"><span>{copy.category}</span><span className={`inbox-severity inbox-severity-${item.severity}`}>{item.severity}</span><time dateTime={item.delivered_at}>{time(item.delivered_at)}</time></div></div>
          <div className="inbox-row-actions">{source && <Link href={source} prefetch={false} className="btn-primary">Open source <ArrowRight size={14} /></Link>}
            <button type="button" className="btn-ghost" disabled={pending !== null} onClick={() => mark(item)}>{pending === item.event_id ? "Saving…" : item.read_at ? "Mark unread" : "Mark read"}</button></div>
        </li>; })}</ul>}
    {compact && items.length > 5 && <p className="inbox-note p-4">Showing the latest five unread notices. Open the full inbox for more.</p>}
    {!compact && enabled && !error && (cursor || next) && <footer className="inbox-pagination"><span>Up to 30 notices per page</span>
      {cursor && <button type="button" className="btn-secondary" onClick={() => { setItems([]); setCursor(undefined); }}>Latest notices</button>}
      {next && <button type="button" className="btn-secondary" disabled={loading} onClick={() => { setItems([]); setCursor(next); }}>Older notices <ArrowRight size={14} /></button>}</footer>}
  </section>;
}

function InboxPreferences() {
  const { data, refresh } = useStaffAttention();
  const [value, setValue] = useState<boolean | null>(null), [pending, setPending] = useState(false), [message, setMessage] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    if (data?.enabled) inboxRequest(new URLSearchParams({ mode: "preferences" }), controller.signal)
      .then(result => setValue(typeof result.assignment_notifications === "boolean" ? result.assignment_notifications : null))
      .catch(() => { if (!controller.signal.aborted) setMessage("Preferences could not be loaded. Close and reopen to retry."); });
    return () => controller.abort();
  }, [data?.enabled]);
  return <section className="inbox-preferences" aria-label="Notification preferences"><h2>Assignment preferences</h2><p>Only future optional assignment notices can be muted. Critical assignments, overdue responses, and legal approvals stay visible.</p>
    <label><input type="checkbox" checked={value ?? false} disabled={value === null || pending || !data?.enabled} onChange={async event => {
      const desired = event.target.checked; setPending(true); setMessage("");
      try { const result = await inboxRequest(new URLSearchParams(), AbortSignal.timeout(12_000), { action: "preferences", assignmentNotifications: desired }); setValue(result.assignment_notifications); setMessage("Preference saved."); refresh(); }
      catch { setMessage("Preference was not saved. Your previous setting is unchanged; retry."); } finally { setPending(false); }
    }} /> Receive optional assignment notifications</label><p role="status">{message || (pending ? "Saving…" : !data?.enabled ? "Available when your inbox pilot is enabled." : value === null ? "Loading preference…" : "")}</p></section>;
}
