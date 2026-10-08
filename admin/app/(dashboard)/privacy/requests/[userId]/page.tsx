import Link from "next/link";
import { notFound } from "next/navigation";
import { createAdminClient } from "@/lib/supabase/server";
import { getOperationalRole } from "@/lib/governance";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { DataWarning } from "@/components/ui/operations";
import { WorkflowForm } from "@/components/workflows/workflow-form";
import { randomUUID } from "node:crypto";
import { createSsrClient } from "@/lib/supabase/server";
import { openPrivacyRequest, privacyCommand, sendPrivacyExport, clearPrivacyExport } from "@/lib/privacy-actions";

export const dynamic = "force-dynamic";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type UserRow = { user_id: string; display_name: string; anonymous_pseudonym: string; account_status: string; created_at: string; deactivated_at: string | null; deletion_requested_at: string | null };
type Hold = { case_id: string; target_type: string; status: string; severity: string; policy_code: string | null; evidence_hash: string; opened_at: string };
type PrivacyEvent = { kind: string; note: string | null; at: string; actor: string };
type PrivacyRequest = {
  request_id: string; kind: string; source: string; state: string; due_at: string; identity_note: string | null; support_case_id: string | null;
  overdue: boolean; export_path: string | null; export_sent_at: string | null; export_expires_at: string | null; outcome_note: string | null;
  closed_at: string | null; created_at: string; version: number; assignee_name: string | null; events: PrivacyEvent[];
};
type AuditRow = { audit_id: string; actor_pseudonym: string; action: string; reason: string | null; created_at: string };

export default async function PrivacyRequestDetailPage({ params }: { params: Promise<{ userId: string }> }) {
  if(!["super_admin","admin"].includes(await getOperationalRole()??""))notFound();
  const { userId } = await params;
  if (!UUID.test(userId)) notFound();
  const db = await createAdminClient();
  const userResult = await db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, created_at, deactivated_at, deletion_requested_at").eq("user_id", userId).maybeSingle();
  if (userResult.error) return <ErrorPanel title="Privacy request unavailable" detail="The account source could not be loaded. Refresh to retry; this does not mean the account was deleted." />;
  if (!userResult.data) notFound();
  const user = userResult.data as UserRow;
  const [posts, comments, whispers, tribeMessages, chats, sessions, security, holdsResult, auditResult] = await Promise.all([
    db.from("posts").select("post_id", { count: "exact", head: true }).eq("author_id", userId),
    db.from("posts_comments").select("comment_id", { count: "exact", head: true }).eq("author_id", userId),
    db.from("whispers").select("whisper_id", { count: "exact", head: true }).eq("author_id", userId),
    db.from("tribe_messages").select("message_id", { count: "exact", head: true }).eq("sender_id", userId),
    db.from("chat_messages").select("message_id", { count: "exact", head: true }).eq("sender_id", userId),
    db.from("device_sessions").select("device_session_id", { count: "exact", head: true }).eq("user_id", userId),
    db.from("security_events").select("event_id", { count: "exact", head: true }).eq("user_id", userId),
    db.from("moderation_cases").select("case_id, target_type, status, severity, policy_code, evidence_hash, opened_at").eq("legal_hold", true).or(`target_id.eq.${userId},subject_id.eq.${userId}`).order("opened_at", { ascending: false }).limit(100),
    db.from("audit_log").select("audit_id, actor_pseudonym, action, reason, created_at").eq("target_id", userId).order("created_at", { ascending: false }).limit(50),
  ]);
  const ssr = await createSsrClient();
  const privacyResult = await ssr.rpc("admin_privacy_member_requests", { p_member: userId });
  const privacy = privacyResult.data as { email_available: boolean; requests: PrivacyRequest[] } | null;
  const privacyRequests = privacy?.requests ?? [];
  const results = [posts, comments, whispers, tribeMessages, chats, sessions, security, holdsResult, auditResult, privacyResult];
  const incomplete = results.some((result) => result.error);
  const holds = (holdsResult.data ?? []) as Hold[];
  const audit = (auditResult.data ?? []) as AuditRow[];
  const inventory = [
    ["Vents", posts.error ? null : posts.count], ["Comments", comments.error ? null : comments.count], ["Whispers", whispers.error ? null : whispers.count], ["Tribe messages", tribeMessages.error ? null : tribeMessages.count],
    ["Direct/group messages", chats.error ? null : chats.count], ["Device sessions", sessions.error ? null : sessions.count], ["Security events", security.error ? null : security.count],
  ] as const;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Privacy request" title={user.display_name} subtitle={`@${user.anonymous_pseudonym} · data-minimized request dossier`} actions={<div className="flex gap-2"><Link href={`/users/${user.user_id}`} className="btn-secondary">Account</Link><Link href="/privacy" className="btn-secondary">All requests</Link></div>} />
      {!privacyResult.error && privacy && !privacy.email_available && <DataWarning caveat title="No verified email address">This member cannot be sent a data export until they verify an email address in Settings.</DataWarning>}
      {incomplete && <ErrorPanel title="Privacy inventory is incomplete" detail="One or more inventory sources could not be loaded. Refresh to retry." hint="Never fulfil a request while a required source is unknown." />}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Card><p className="h-eyebrow">Open privacy requests</p><p className="mt-1 text-3xl font-extrabold text-burgundy">{privacyResult.error ? "—" : privacyRequests.filter(isOpen).length}</p>{privacyRequests.some((r) => isOpen(r) && r.overdue) ? <Badge tone="danger">overdue</Badge> : user.deletion_requested_at ? <Badge tone="warn">deletion pending</Badge> : <Badge tone="ok">on time</Badge>}</Card>
        <Card><p className="h-eyebrow">Account state</p><div className="mt-2"><Badge tone={user.account_status === "active" ? "info" : "warn"}>{user.account_status}</Badge></div><p className="mt-2 text-xs text-ink-muted">Created {new Date(user.created_at).toLocaleDateString()}</p></Card>
        <Card><p className="h-eyebrow">Legal holds shown · latest 100</p><p className="mt-1 text-3xl font-extrabold text-burgundy">{holdsResult.error ? "—" : holds.length}</p><Badge tone={holdsResult.error ? "neutral" : holds.length > 0 ? "danger" : "ok"}>{holdsResult.error ? "unknown" : holds.length > 0 ? "blocks erasure" : "none returned"}</Badge></Card>
      </div>
      <PrivacyRequests memberId={user.user_id} requests={privacyRequests} unavailable={Boolean(privacyResult.error)} emailAvailable={privacy?.email_available ?? false} />
      <Card title="Data-system inventory" hint="Counts only; content and identifiers are not rendered">
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          {inventory.map(([label, count]) => <div key={label} className="surface-flat p-3"><p className="text-xs text-ink-muted">{label}</p><p className="mt-1 text-xl font-extrabold text-burgundy">{count ?? "—"}</p></div>)}
        </div>
      </Card>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Retention exceptions" hint="Legal holds tied to this member" padded={false}>
          {holds.length === 0 ? <p className="px-5 py-10 text-center text-sm italic text-ink-muted">{holdsResult.error ? "Legal holds could not be verified." : "No active legal hold returned."}</p> : <ul className="divide-y divide-line">{holds.map((hold) => <li key={hold.case_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone="danger">legal hold</Badge><Badge>{hold.severity}</Badge><span className="text-xs text-ink-muted">{hold.policy_code ?? hold.target_type}</span></div><Link href={`/moderation/cases/${hold.case_id}`} className="mt-1 block text-xs font-bold text-berry hover:underline">Open case dossier</Link><p className="mt-1 font-mono text-[10px] text-ink-muted">evidence {hold.evidence_hash.slice(0, 20)}…</p></li>)}</ul>}
        </Card>
        <Card title="Account-targeted audit activity" hint="Latest 50 metadata records" padded={false}>
          {audit.length === 0 ? <p className="px-5 py-10 text-center text-sm italic text-ink-muted">No matching audit rows returned.</p> : <ul className="divide-y divide-line">{audit.map((row) => <li key={row.audit_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge>{row.action}</Badge><span className="text-xs text-ink-muted">@{row.actor_pseudonym}</span><time className="ml-auto text-[11px] text-ink-muted">{new Date(row.created_at).toLocaleString()}</time></div>{row.reason && <p className="mt-1 text-xs text-ink-muted">{row.reason.slice(0, 180)}</p>}</li>)}</ul>}
        </Card>
      </div>
    </div>
  );
}

const KIND_LABEL: Record<string, string> = { access: "Copy of their data", deletion: "Delete account", correction: "Correct data", objection: "Object to processing", other: "Other privacy question" };
const SOURCE_LABEL: Record<string, string> = { deletion_request: "asked in the app", support: "wrote to support", staff: "opened by staff" };
const EVENT_LABEL: Record<string, string> = { opened: "Opened", started: "Started", completed: "Completed", refused: "Refused", withdrawn: "Withdrawn", erased: "Account erased", export_sent: "Export emailed", export_cleared: "Export file deleted" };
const isOpen = (r: { state: string }) => r.state === "received" || r.state === "in_progress";

function PrivacyRequests({ memberId, requests, unavailable, emailAvailable }: { memberId: string; requests: PrivacyRequest[]; unavailable: boolean; emailAvailable: boolean }) {
  const ids = (r: PrivacyRequest) => <><input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="request_id" value={r.request_id} /><input type="hidden" name="member_id" value={memberId} /><input type="hidden" name="version" value={r.version} /></>;
  return (
    <Card title="Privacy requests" hint="Each request is due 30 days after it was received" padded={false}>
      {unavailable ? <p className="px-5 py-10 text-center text-sm italic text-ink-muted">Privacy requests could not be loaded. Refresh to retry.</p>
        : requests.length === 0 ? <p className="px-5 py-8 text-center text-sm italic text-ink-muted">No privacy requests from this member.</p>
        : <ul className="divide-y divide-line">{requests.map((r) => {
          const open = isOpen(r);
          const exportable = open && (r.kind === "access" || r.kind === "other");
          const expired = r.export_expires_at ? new Date(r.export_expires_at) < new Date() : false;
          return <li key={r.request_id} className="px-5 py-4">
            <div className="flex flex-wrap items-center gap-2">
              <p className="font-bold text-burgundy">{KIND_LABEL[r.kind] ?? r.kind}</p>
              <Badge tone={r.state === "completed" ? "ok" : r.state === "refused" || r.overdue ? "danger" : open ? "warn" : "neutral"}>{r.overdue ? "overdue" : r.state.replace("_", " ")}</Badge>
              <span className="text-xs text-ink-muted">{SOURCE_LABEL[r.source] ?? r.source}{r.assignee_name ? ` · with ${r.assignee_name}` : ""}</span>
              <span className="ml-auto text-[11px] text-ink-muted">{open ? `due ${new Date(r.due_at).toLocaleDateString()}` : r.closed_at ? `closed ${new Date(r.closed_at).toLocaleDateString()}` : ""}</span>
            </div>
            {r.identity_note && <p className="mt-1 text-xs text-ink-muted">Identity: {r.identity_note}</p>}
            {r.support_case_id && <Link href={`/support/cases/${r.support_case_id}`} className="mt-1 inline-block text-xs text-berry hover:underline">Open the support conversation</Link>}
            {r.outcome_note && <p className="mt-1 text-xs text-ink">Outcome: {r.outcome_note}</p>}
            {r.export_sent_at && <p className="mt-1 text-xs text-ink-muted">Export emailed {new Date(r.export_sent_at).toLocaleString()}{r.export_path ? (expired ? " · link expired, file still stored" : ` · link valid until ${new Date(r.export_expires_at!).toLocaleString()}`) : " · file deleted"}</p>}
            <ol className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-ink-muted">{r.events.map((e, i) => <li key={i}>{EVENT_LABEL[e.kind] ?? e.kind} · {e.actor} · {new Date(e.at).toLocaleString()}</li>)}</ol>
            {r.kind === "deletion" && open && <p className="mt-2 text-xs text-ink-muted">Closes itself when the scheduled purge erases the account, or if the member cancels.</p>}
            <div className="mt-3 grid gap-4 md:grid-cols-2">
              {r.state === "received" && <WorkflowForm action={privacyCommand} blockUncertainRetry label="Start working on it" confirmation="Marks this request as in progress and assigns it to you.">
                {ids(r)}<input type="hidden" name="command" value="start" />
              </WorkflowForm>}
              {exportable && <WorkflowForm action={sendPrivacyExport} blockUncertainRetry disabled={!emailAvailable} label="Send data export"
                confirmation="Builds a file of everything Venttly holds about this member (secrets excluded), stores it privately and emails them a download link valid for 7 days.">
                {ids(r)}<p className="text-xs text-ink-muted">{emailAvailable ? "Goes to their verified email address only." : "Unavailable: no verified email address."}</p>
              </WorkflowForm>}
              {r.export_path && <WorkflowForm action={clearPrivacyExport} blockUncertainRetry label="Delete export file"
                confirmation="Deletes the stored export. The emailed link stops working.">
                {ids(r)}<p className="text-xs text-ink-muted">{expired ? "The link has expired; delete the file now." : "Do this once the member has downloaded it, or after 7 days."}</p>
              </WorkflowForm>}
              {open && r.kind !== "deletion" && <WorkflowForm action={privacyCommand} blockUncertainRetry label="Complete request" confirmation="Closes the request as fulfilled. The outcome note is kept on the record.">
                {ids(r)}<input type="hidden" name="command" value="complete" />
                <label className="contact-field"><span>What was done</span><textarea name="note" className="input" required minLength={3} maxLength={1000} rows={2} placeholder="e.g. export sent and downloaded" /></label>
              </WorkflowForm>}
              {open && r.kind !== "deletion" && <WorkflowForm action={privacyCommand} blockUncertainRetry label="Refuse request" confirmation="Closes the request as refused. Tell the member why through support as well.">
                {ids(r)}<input type="hidden" name="command" value="refuse" />
                <label className="contact-field"><span>Reason</span><textarea name="note" className="input" required minLength={3} maxLength={1000} rows={2} placeholder="e.g. identity could not be confirmed" /></label>
              </WorkflowForm>}
            </div>
          </li>;
        })}</ul>}
      {!unavailable && <div className="border-t border-line px-5 py-4">
        <WorkflowForm action={openPrivacyRequest} blockUncertainRetry label="Open a request" confirmation="Records a new privacy request for this member, due in 30 days.">
          <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="member_id" value={memberId} />
          <div className="grid gap-3 md:grid-cols-2">
            <label className="contact-field"><span>Kind</span><select name="kind" className="select" defaultValue="access">{Object.entries(KIND_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
            <label className="contact-field"><span>How you confirmed it is them</span><input name="identity_note" className="input" required minLength={3} maxLength={500} placeholder="e.g. wrote from their signed-in account" /></label>
          </div>
        </WorkflowForm>
      </div>}
    </Card>
  );
}
