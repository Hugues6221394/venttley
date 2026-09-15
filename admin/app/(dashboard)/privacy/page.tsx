import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, Pagination, positivePage } from "@/components/ui/operations";
import { FileLock2 } from "@/components/ui/icons";

export const dynamic = "force-dynamic";
const PAGE_SIZE = 50;

type DeletionRequest = { user_id: string; display_name: string; anonymous_pseudonym: string; account_status: string; deletion_requested_at: string };
type LegalHold = { case_id: string; target_type: string; target_id: string; status: string; evidence_hash: string; opened_at: string; updated_at: string };

export default async function PrivacyPage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  const { page: rawPage } = await searchParams;
  const page = positivePage(rawPage);
  const from = (page - 1) * PAGE_SIZE;
  const db = await createAdminClient();
  const [requestsResult, holdsResult, deactivated, pendingDeletion] = await Promise.all([
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, deletion_requested_at", { count: "exact" }).not("deletion_requested_at", "is", null).order("deletion_requested_at", { ascending: true }).range(from, from + PAGE_SIZE - 1),
    db.from("moderation_cases").select("case_id, target_type, target_id, status, evidence_hash, opened_at, updated_at").eq("legal_hold", true).order("updated_at", { ascending: false }).limit(100),
    db.from("users").select("user_id", { count: "exact", head: true }).not("deactivated_at", "is", null),
    db.from("users").select("user_id", { count: "exact", head: true }).not("deletion_requested_at", "is", null),
  ]);
  const errors = [requestsResult, holdsResult, deactivated, pendingDeletion].flatMap((result) => result.error ? [result.error.message] : []);
  const requests = (requestsResult.data ?? []) as DeletionRequest[];
  const holds = (holdsResult.data ?? []) as LegalHold[];

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Manage" title="Privacy & data rights" subtitle="Deletion requests and legal holds without exposing recovery data, contact details, device identifiers, or authored content." actions={<Link href="/audit" className="btn-secondary">Privacy audit trail</Link>} />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Metric label="Pending deletion requests" value={pendingDeletion.count} attention={(pendingDeletion.count ?? 0) > 0} />
        <Metric label="Active legal holds" value={holds.length} attention={holds.length > 0} />
        <Metric label="Deactivated profiles retained" value={deactivated.count} attention={(deactivated.count ?? 0) > 0} />
      </div>
      {errors.length > 0 && <ErrorPanel title="Privacy queue data is incomplete" detail={errors.join("\n")} hint="Do not infer that a request or hold does not exist while a source is unavailable." />}
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Deletion requests" hint="Oldest first" padded={false}>
          {requests.length === 0 ? <EmptyState icon={<FileLock2 size={30} />} title="No deletion requests returned." hint={errors.length ? "The query failed or returned partial data." : "Nothing is waiting in the current queue."} /> : <><ul className="divide-y divide-line">{requests.map((request) => <li key={request.user_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Link href={`/privacy/requests/${request.user_id}`} className="font-bold text-burgundy hover:text-berry">{request.display_name}</Link><span className="text-xs text-ink-muted">@{request.anonymous_pseudonym}</span><Badge tone="warn">{request.account_status}</Badge></div><p className="mt-1 text-[11px] text-ink-muted">requested {new Date(request.deletion_requested_at).toLocaleString()}</p><Link href={`/privacy/requests/${request.user_id}`} className="mt-1 inline-block text-xs text-berry hover:underline">Open request dossier</Link></li>)}</ul><Pagination basePath="/privacy" page={page} pageSize={PAGE_SIZE} total={requestsResult.count ?? 0} /></>}
        </Card>
        <Card title="Legal holds" hint="Evidence retained against deletion" padded={false}>
          {holds.length === 0 ? <EmptyState icon={<FileLock2 size={30} />} title="No active legal holds returned." hint={errors.length ? "The source is not fully available." : "No moderation evidence is currently marked for exceptional retention."} /> : <ul className="divide-y divide-line">{holds.map((hold) => <li key={hold.case_id} className="px-5 py-3"><div className="flex items-center gap-2"><Badge tone="danger">legal hold</Badge><p className="text-sm font-bold text-burgundy">{hold.target_type.replaceAll("_", " ")}</p><Badge>{hold.status}</Badge></div><Link href={`/moderation/cases/${hold.case_id}`} className="mt-2 block text-xs text-berry hover:underline">Open case dossier</Link><p className="mt-1 font-mono text-[10px] text-ink-muted">evidence {hold.evidence_hash.slice(0, 20)}…</p></li>)}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Fulfilment actions need a privacy workflow, not a delete button">
        Identity verification, export generation, retention exceptions, legal-hold
        approval, deletion progress, and completion evidence need a dedicated
        audited state machine. Until then, this page identifies work but does not
        claim a request was fulfilled.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, attention }: { label: string; value: number | null; attention: boolean }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-2xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : attention ? "warn" : "ok"}>{value === null ? "unknown" : attention ? "review" : "clear"}</Badge></div></Card>;
}
