import Link from "next/link";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Eye } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type CsamAccess = {
  access_id: string;
  incident_id: string;
  actor_pseudonym: string;
  actor_role: string;
  reason: string;
  fields_read: string[];
  accessed_at: string;
};

type CaseAccess = {
  audit_id: string;
  actor_pseudonym: string;
  actor_role: string;
  target_id: string | null;
  reason: string | null;
  created_at: string;
};

export default async function EvidenceAccessPage() {
  const ssr = await createSsrClient();
  const db = await createAdminClient();
  const [csamResult, caseResult, csamCount, caseCount] = await Promise.all([
    ssr.rpc("admin_csam_access_log", { p_incident: null, p_limit: 100 }),
    db.from("audit_log").select("audit_id, actor_pseudonym, actor_role, target_id, reason, created_at").eq("action", "case.read_sensitive_evidence").order("created_at", { ascending: false }).limit(100),
    db.from("csam_evidence_access").select("access_id", { count: "exact", head: true }),
    db.from("audit_log").select("audit_id", { count: "exact", head: true }).eq("action", "case.read_sensitive_evidence"),
  ]);
  const errors = [csamResult.error, caseResult.error, csamCount.error, caseCount.error].filter(Boolean).map((error) => error!.message);
  const csam = (csamResult.data ?? []) as CsamAccess[];
  const cases = (caseResult.data ?? []) as CaseAccess[];

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Manage" title="Evidence access review" subtitle="Who disclosed restricted evidence, when, which fields, and why. Evidence values, media URLs, message bodies, and before/after snapshots are not rendered." actions={<Link href="/audit" className="btn-secondary">Full audit log</Link>} />
      <DataWarning caveat title="Access records are not the evidence">
        This page is safe for access review because it shows disclosure metadata
        only. Opening evidence remains a separate AAL2-gated, reason-required
        action inside the relevant case or child-safety workflow.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Evidence-access ledger is incomplete" detail={errors.join("\n")} hint="A missing query must never be interpreted as no disclosure." />}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Metric label="CSAM evidence disclosures" value={csamCount.count} />
        <Metric label="Sensitive case disclosures" value={caseCount.count} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Child-safety evidence access" hint="Latest 100 · dedicated append-only ledger" padded={false}>
          {csam.length === 0 ? <EmptyState icon={<Eye size={30} />} title="No CSAM evidence disclosures returned." hint={errors.length ? "The ledger could not be fully read." : "No evidence has been disclosed through the audited RPC."} /> : (
            <ul className="divide-y divide-line">
              {csam.map((row) => (
                <li key={row.access_id} className="px-5 py-3">
                  <div className="flex flex-wrap items-center gap-2"><Badge tone="danger">restricted</Badge><span className="text-xs font-bold text-burgundy">@{row.actor_pseudonym}</span><Badge>{row.actor_role.replaceAll("_", " ")}</Badge><time className="ml-auto text-[11px] text-ink-muted">{new Date(row.accessed_at).toLocaleString()}</time></div>
                  <p className="mt-1 text-xs text-ink-muted">Reason: {row.reason}</p>
                  <p className="mt-1 text-[11px] text-ink-muted">Fields disclosed: {row.fields_read.join(", ")}</p>
                  <Link href={`/csam?incident=${row.incident_id}`} className="mt-1 inline-block text-xs font-bold text-berry hover:underline">Open restricted incident</Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Private case evidence access" hint="Latest 100 · audit ledger projection" padded={false}>
          {cases.length === 0 ? <EmptyState icon={<Eye size={30} />} title="No sensitive case disclosures returned." hint={errors.length ? "The audit source is incomplete." : "No private case evidence has been disclosed through the audited RPC."} /> : (
            <ul className="divide-y divide-line">
              {cases.map((row) => (
                <li key={row.audit_id} className="px-5 py-3">
                  <div className="flex flex-wrap items-center gap-2"><Badge tone="warn">private evidence</Badge><span className="text-xs font-bold text-burgundy">@{row.actor_pseudonym}</span><Badge>{row.actor_role.replaceAll("_", " ")}</Badge><time className="ml-auto text-[11px] text-ink-muted">{new Date(row.created_at).toLocaleString()}</time></div>
                  <p className="mt-1 text-xs text-ink-muted">Reason: {row.reason ?? "No reason recorded"}</p>
                  {row.target_id && <Link href={`/moderation/cases/${row.target_id}`} className="mt-1 inline-block text-xs font-bold text-berry hover:underline">Open case dossier</Link>}
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
      <CapabilityNotice title="Anomaly alerting and exports remain backend work">
        Production review still needs unusual-access alerts, scheduled access
        certification, immutable export manifests, short-lived encrypted
        downloads, and retention enforcement. Direct evidence export is not
        exposed by this page.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: number | null }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : (value ?? 0) > 0 ? "info" : "ok"}>{value === null ? "unknown" : (value ?? 0) > 0 ? "recorded" : "none"}</Badge></div></Card>;
}
