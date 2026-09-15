import Link from "next/link";
import { notFound } from "next/navigation";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";

export const dynamic = "force-dynamic";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type UserRow = { user_id: string; display_name: string; anonymous_pseudonym: string; account_status: string; created_at: string; deactivated_at: string | null; deletion_requested_at: string | null };
type Hold = { case_id: string; target_type: string; status: string; severity: string; policy_code: string | null; evidence_hash: string; opened_at: string };
type AuditRow = { audit_id: string; actor_pseudonym: string; action: string; reason: string | null; created_at: string };

export default async function PrivacyRequestDetailPage({ params }: { params: Promise<{ userId: string }> }) {
  const { userId } = await params;
  if (!UUID.test(userId)) notFound();
  const db = await createAdminClient();
  const userResult = await db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, created_at, deactivated_at, deletion_requested_at").eq("user_id", userId).maybeSingle();
  if (userResult.error || !userResult.data) notFound();
  const user = userResult.data as UserRow;
  const [posts, comments, whispers, tribeMessages, chats, sessions, security, holdsResult, auditResult] = await Promise.all([
    db.from("posts").select("post_id", { count: "exact", head: true }).eq("author_id", userId),
    db.from("posts_comments").select("comment_id", { count: "exact", head: true }).eq("author_id", userId),
    db.from("whispers").select("whisper_id", { count: "exact", head: true }).eq("author_id", userId),
    db.from("tribe_messages").select("message_id", { count: "exact", head: true }).eq("sender_id", userId),
    db.from("chat_messages").select("message_id", { count: "exact", head: true }).eq("sender_id", userId),
    db.from("device_sessions").select("device_session_id", { count: "exact", head: true }).eq("user_id", userId),
    db.from("security_events").select("event_id", { count: "exact", head: true }).eq("user_id", userId),
    db.from("moderation_cases").select("case_id, target_type, status, severity, policy_code, evidence_hash, opened_at").eq("legal_hold", true).or(`target_id.eq.${userId},subject_id.eq.${userId}`).order("opened_at", { ascending: false }),
    db.from("audit_log").select("audit_id, actor_pseudonym, action, reason, created_at").eq("target_id", userId).order("created_at", { ascending: false }).limit(50),
  ]);
  const results = [posts, comments, whispers, tribeMessages, chats, sessions, security, holdsResult, auditResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const holds = (holdsResult.data ?? []) as Hold[];
  const audit = (auditResult.data ?? []) as AuditRow[];
  const inventory = [
    ["Vents", posts.count], ["Comments", comments.count], ["Whispers", whispers.count], ["Tribe messages", tribeMessages.count],
    ["Direct/group messages", chats.count], ["Device sessions", sessions.count], ["Security events", security.count],
  ] as const;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Privacy request" title={user.display_name} subtitle={`@${user.anonymous_pseudonym} · data-minimized request dossier`} actions={<div className="flex gap-2"><Link href={`/users/${user.user_id}`} className="btn-secondary">Account</Link><Link href="/privacy" className="btn-secondary">All requests</Link></div>} />
      {!user.deletion_requested_at && <DataWarning title="No active deletion request is recorded">This dossier remains available for investigation, but the account does not currently have a deletion-request timestamp.</DataWarning>}
      {errors.length > 0 && <ErrorPanel title="Privacy inventory is incomplete" detail={errors.join("\n")} hint="Never fulfil a request while a required source is unknown." />}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Card><p className="h-eyebrow">Request state</p><div className="mt-2"><Badge tone={user.deletion_requested_at ? "warn" : "neutral"}>{user.deletion_requested_at ? "pending" : "not requested"}</Badge></div>{user.deletion_requested_at && <p className="mt-2 text-xs text-ink-muted">{new Date(user.deletion_requested_at).toLocaleString()}</p>}</Card>
        <Card><p className="h-eyebrow">Account state</p><div className="mt-2"><Badge tone={user.account_status === "active" ? "info" : "warn"}>{user.account_status}</Badge></div><p className="mt-2 text-xs text-ink-muted">Created {new Date(user.created_at).toLocaleDateString()}</p></Card>
        <Card><p className="h-eyebrow">Active legal holds</p><p className="mt-1 text-3xl font-extrabold text-burgundy">{holds.length}</p><Badge tone={holds.length > 0 ? "danger" : "ok"}>{holds.length > 0 ? "blocks erasure" : "none returned"}</Badge></Card>
      </div>
      <Card title="Data-system inventory" hint="Counts only; content and identifiers are not rendered">
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          {inventory.map(([label, count]) => <div key={label} className="surface-flat p-3"><p className="text-xs text-ink-muted">{label}</p><p className="mt-1 text-xl font-extrabold text-burgundy">{count ?? "—"}</p></div>)}
        </div>
      </Card>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Retention exceptions" hint="Legal holds tied to this member" padded={false}>
          {holds.length === 0 ? <p className="px-5 py-10 text-center text-sm italic text-ink-muted">No active legal hold returned.</p> : <ul className="divide-y divide-line">{holds.map((hold) => <li key={hold.case_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone="danger">legal hold</Badge><Badge>{hold.severity}</Badge><span className="text-xs text-ink-muted">{hold.policy_code ?? hold.target_type}</span></div><Link href={`/moderation/cases/${hold.case_id}`} className="mt-1 block text-xs font-bold text-berry hover:underline">Open case dossier</Link><p className="mt-1 font-mono text-[10px] text-ink-muted">evidence {hold.evidence_hash.slice(0, 20)}…</p></li>)}</ul>}
        </Card>
        <Card title="Account-targeted audit activity" hint="Latest 50 metadata records" padded={false}>
          {audit.length === 0 ? <p className="px-5 py-10 text-center text-sm italic text-ink-muted">No matching audit rows returned.</p> : <ul className="divide-y divide-line">{audit.map((row) => <li key={row.audit_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge>{row.action}</Badge><span className="text-xs text-ink-muted">@{row.actor_pseudonym}</span><time className="ml-auto text-[11px] text-ink-muted">{new Date(row.created_at).toLocaleString()}</time></div>{row.reason && <p className="mt-1 text-xs text-ink-muted">{row.reason.slice(0, 180)}</p>}</li>)}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Fulfilment remains deliberately unavailable">
        Identity verification, deadline computation, processor fanout, legal-hold
        approval, retry-safe deletion, completion evidence, and independent
        approval require a canonical privacy workflow. A direct cascade-delete
        button would be unsafe and unauditable.
      </CapabilityNotice>
    </div>
  );
}
