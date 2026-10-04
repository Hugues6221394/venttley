import { randomUUID } from "node:crypto";
import { createSupportCase, updateSupportCase } from "./actions";
import { OperationResult } from "@/components/operation-result";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { getSupportCases, getLinkedQueue, type SupportCase } from "@/lib/governance";
import Link from "next/link";
import { workflowUIEnabled } from '@/lib/workflows';
import { SupportWorkspace } from '@/components/workflows/support-workspace';
import { RefreshAttentionOnRender } from "@/components/staff-attention";
import { QueueAttentionPanel } from "@/components/queue-attention-panel";

export const dynamic = "force-dynamic";

const statusTone = (status: string) => status === "closed" || status === "resolved" ? "ok" : "warn" as const;

export default async function SupportCasesPage({ searchParams }: { searchParams: Promise<Record<string,string|undefined>> }) {
  const params = await searchParams;
  if(await workflowUIEnabled())return <SupportWorkspace params={params}/>;
  const { result, queue: queueFilter, source } = params;
  const queue = queueFilter || source ? await getLinkedQueue<SupportCase>("support", queueFilter ?? "all", source) : await getSupportCases();
  return <div className="flex max-w-[1500px] flex-col gap-6">
    <RefreshAttentionOnRender token={randomUUID()} />
    <PageHeader eyebrow="Member operations" title="Support cases" subtitle="Canonical metadata-only cases with SLA ownership, retry-safe mutations, and a complete operator audit trail. Never paste confession or message content here." />
    <QueueAttentionPanel queue="support" />
    <OperationResult code={result} />
    {(queueFilter || source) && <p className="text-sm text-ink-muted">{source ? "Notification source case" : "Open support cases"} · <Link className="underline" href="/support/cases" prefetch={false}>Show all cases</Link></p>}
    {queue.error && <DataWarning title="Support queue unavailable">{queue.error}</DataWarning>}
    <Card title="Open a case" hint="AAL2 required · source IDs are verified when bound to an appeal or verification request">
      <form action={createSupportCase} className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <input type="hidden" name="operation_id" value={randomUUID()} />
        <label className="field-label">Source<select name="source_kind" className="input mt-1" defaultValue="other"><option value="appeal">Appeal</option><option value="verification">Verification</option><option value="privacy">Privacy</option><option value="account">Account</option><option value="recovery">Recovery</option><option value="safety">Safety</option><option value="other">Other</option></select></label>
        <label className="field-label">Category<select name="category" className="input mt-1" defaultValue="technical"><option value="access">Access</option><option value="appeal_help">Appeal help</option><option value="verification_help">Verification help</option><option value="privacy_request">Privacy request</option><option value="recovery_help">Recovery help</option><option value="safety_followup">Safety follow-up</option><option value="technical">Technical</option><option value="other">Other</option></select></label>
        <label className="field-label">Priority<select name="priority" className="input mt-1" defaultValue="normal"><option value="low">Low · 72h</option><option value="normal">Normal · 24h</option><option value="high">High · 4h</option><option value="critical">Critical · 15m</option></select></label>
        <label className="field-label">Source UUID<input name="source_id" className="input mt-1" inputMode="text" placeholder="Optional appeal/verification UUID" /></label>
        <label className="field-label">Member UUID<input name="member_id" className="input mt-1" inputMode="text" placeholder="Optional affected member" /></label>
        <div className="flex items-end"><button className="btn-primary" type="submit">Create case</button></div>
      </form>
    </Card>
    <Card title="Case queue" hint={`${queue.data.length} most recent cases · earliest SLA first`} padded={false}>
      {queue.data.length === 0 ? <p className="p-5 text-sm text-ink-muted">{queue.error ? "Cases could not be verified." : "No cases match this view."}</p> : <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Case</th><th>Owner / SLA</th><th>State</th><th>Update</th></tr></thead><tbody>
        {queue.data.map((item) => <tr key={item.support_case_id}>
          <td><p className="font-semibold text-burgundy">{item.category.replaceAll("_", " ")}</p><p className="text-xs text-ink-muted">{item.source_kind}{item.member_id ? " · member bound" : ""}</p><p className="font-mono text-[10px] text-ink-muted">{item.support_case_id}</p></td>
          <td><p className="text-xs">{item.assignee_name ?? "Unassigned"}</p><p className="text-[11px] text-ink-muted">Due {new Date(item.sla_due_at).toLocaleString()}</p></td>
          <td><div className="flex flex-col items-start gap-1"><Badge tone={statusTone(item.status)}>{item.status.replaceAll("_", " ")}</Badge><Badge tone={item.priority === "critical" ? "danger" : item.priority === "high" ? "warn" : "neutral"}>{item.priority}</Badge></div></td>
          <td><form action={updateSupportCase} className="flex min-w-[460px] flex-wrap items-end gap-2">
            <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="case_id" value={item.support_case_id} />
            <label className="field-label">Status<select name="status" className="select mt-1" defaultValue={item.status}><option value="open">Open</option><option value="assigned">Assigned</option><option value="waiting_member">Waiting member</option><option value="waiting_internal">Waiting internal</option><option value="resolved">Resolved</option><option value="closed">Closed</option></select></label>
            <label className="field-label">Priority<select name="priority" className="select mt-1" defaultValue={item.priority}><option value="low">Low</option><option value="normal">Normal</option><option value="high">High</option><option value="critical">Critical</option></select></label>
            <label className="field-label">Assignee UUID<input name="assignee_id" className="input mt-1 w-52" defaultValue={item.assignee_id ?? ""} placeholder="Required if assigned" /></label>
            <button className="btn-secondary" type="submit">Save</button>
          </form></td>
        </tr>)}
      </tbody></table></div>}
    </Card>
    <CapabilityNotice title="Content-minimizing workflow">Cases store category, state, ownership, SLA, and bound record IDs only. Member-authored text belongs in its source system and is revealed only through that system&apos;s audited access path.</CapabilityNotice>
  </div>;
}
