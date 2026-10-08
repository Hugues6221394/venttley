import Link from "next/link";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { getOperationalRole } from "@/lib/governance";
import { notFound } from "next/navigation";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { FileLock2 } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type QueueRow = { request_id: string; member_id: string | null; member_pseudonym: string; member_name: string | null; kind: string; source: string; state: string; due_at: string; overdue: boolean; created_at: string; closed_at: string | null; export_sent_at: string | null; assignee_name: string | null };
type LegalHold = { case_id: string; target_type: string; target_id: string; status: string; evidence_hash: string; opened_at: string; updated_at: string };

const KIND_LABEL: Record<string, string> = { access: "Copy of their data", deletion: "Delete account", correction: "Correct data", objection: "Object to processing", other: "Other privacy question" };

export default async function PrivacyPage({ searchParams }: { searchParams: Promise<{ view?: string }> }) {
  const { view: rawView } = await searchParams;
  const view = rawView === "closed" ? "closed" : "open";
  if(!["super_admin","admin"].includes(await getOperationalRole()??""))notFound();
  const db = await createAdminClient();
  const ssr = await createSsrClient();
  const [queueResult, holdsResult, deactivated] = await Promise.all([
    ssr.rpc("admin_privacy_requests", { p_view: view }),
    db.from("moderation_cases").select("case_id, target_type, target_id, status, evidence_hash, opened_at, updated_at").eq("legal_hold", true).order("updated_at", { ascending: false }).limit(100),
    db.from("users").select("user_id", { count: "exact", head: true }).not("deactivated_at", "is", null),
  ]);
  const incomplete = [queueResult, holdsResult, deactivated].some((result) => result.error);
  const queue = (queueResult.data ?? []) as QueueRow[];
  const holds = (holdsResult.data ?? []) as LegalHold[];
  const overdue = queue.filter((row) => row.overdue).length;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Manage" title="Privacy & data rights" subtitle="Every privacy request tracked to completion within 30 days: copies of data, deletions, corrections and objections." actions={<Link href="/audit" className="btn-secondary">Privacy audit trail</Link>} />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Metric label={view === "open" ? "Open requests" : "Closed requests · latest 200"} value={queueResult.error ? null : queue.length} attention={view === "open" && queue.length > 0} />
        <Metric label="Overdue" value={queueResult.error || view !== "open" ? null : overdue} attention={overdue > 0} />
        <Metric label="Legal holds shown · latest 100" value={holdsResult.error ? null : holds.length} attention={holds.length > 0} />
      </div>
      {incomplete && <ErrorPanel title="Privacy queue data is incomplete" detail="One or more sources could not be loaded. Refresh to retry." hint="Do not infer that a request or hold does not exist while a source is unavailable." />}
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Privacy requests" hint={view === "open" ? "Soonest due first" : "Most recently closed first"} padded={false}>
          <div className="flex gap-2 border-b border-line px-5 py-3">
            <Link href="/privacy" className={view === "open" ? "btn-primary" : "btn-secondary"}>Open</Link>
            <Link href="/privacy?view=closed" className={view === "closed" ? "btn-primary" : "btn-secondary"}>Closed</Link>
          </div>
          {queue.length === 0 ? <EmptyState icon={<FileLock2 size={30} />} title={view === "open" ? "No open privacy requests." : "No closed privacy requests yet."} hint={queueResult.error ? "The queue could not be loaded." : "Requests appear when a member asks to delete their account, writes to support about privacy, or staff open one."} />
            : <ul className="divide-y divide-line">{queue.map((row) => <li key={row.request_id} className="px-5 py-3">
              <div className="flex flex-wrap items-center gap-2">
                {row.member_id ? <Link href={`/privacy/requests/${row.member_id}`} className="font-bold text-burgundy hover:text-berry">{row.member_name ?? row.member_pseudonym}</Link> : <span className="font-bold text-ink-muted">Erased account</span>}
                <span className="text-xs text-ink-muted">@{row.member_pseudonym}</span>
                <Badge tone={row.overdue || row.state === "refused" ? "danger" : row.state === "completed" ? "ok" : row.state === "withdrawn" ? "neutral" : "warn"}>{row.overdue ? "overdue" : row.state.replace("_", " ")}</Badge>
              </div>
              <p className="mt-1 text-xs text-ink">{KIND_LABEL[row.kind] ?? row.kind}{row.assignee_name ? ` · with ${row.assignee_name}` : ""}{row.export_sent_at ? " · export emailed" : ""}</p>
              <p className="mt-1 text-[11px] text-ink-muted">received {new Date(row.created_at).toLocaleDateString()} · {view === "open" ? `due ${new Date(row.due_at).toLocaleDateString()}` : row.closed_at ? `closed ${new Date(row.closed_at).toLocaleDateString()}` : ""}</p>
            </li>)}</ul>}
        </Card>
        <Card title="Legal holds" hint="Evidence retained against deletion" padded={false}>
          {holds.length === 0 ? <EmptyState icon={<FileLock2 size={30} />} title="No active legal holds returned." hint={incomplete ? "The source is not fully available." : "No moderation evidence is currently marked for exceptional retention."} /> : <ul className="divide-y divide-line">{holds.map((hold) => <li key={hold.case_id} className="px-5 py-3"><div className="flex items-center gap-2"><Badge tone="danger">legal hold</Badge><p className="text-sm font-bold text-burgundy">{hold.target_type.replaceAll("_", " ")}</p><Badge>{hold.status}</Badge></div><Link href={`/moderation/cases/${hold.case_id}`} className="mt-2 block text-xs text-berry hover:underline">Open case dossier</Link><p className="mt-1 font-mono text-[10px] text-ink-muted">evidence {hold.evidence_hash.slice(0, 20)}…</p></li>)}</ul>}
          <p className="border-t border-line px-5 py-3 text-xs text-ink-muted">{deactivated.error ? "Deactivated profiles: unknown." : `${(deactivated.count ?? 0).toLocaleString()} deactivated profiles retained.`}</p>
        </Card>
      </div>
    </div>
  );
}

function Metric({ label, value, attention }: { label: string; value: number | null; attention: boolean }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-2xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : attention ? "warn" : "ok"}>{value === null ? "unknown" : attention ? "review" : "clear"}</Badge></div></Card>;
}
