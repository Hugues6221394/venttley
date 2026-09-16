import { randomUUID } from "node:crypto";
import { acknowledgePlaybook, createPlaybook, publishPlaybook } from "./actions";
import { OperationResult } from "@/components/operation-result";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { getCrisisPlaybooks, getOperationalRole } from "@/lib/governance";

export const dynamic = "force-dynamic";

export default async function CrisisPlaybooksPage({ searchParams }: { searchParams: Promise<{ result?: string }> }) {
  const [{ result }, register, role] = await Promise.all([searchParams, getCrisisPlaybooks(), getOperationalRole()]);
  const canDraft = role === "super_admin" || role === "admin";
  const isSuper = role === "super_admin";
  return <div className="flex max-w-[1450px] flex-col gap-6">
    <PageHeader eyebrow="Crisis response" title="Crisis playbooks" subtitle="Versioned, immutable-after-publication response procedures. Creation, publication, and acknowledgement are distinct audited acts." />
    <OperationResult code={result} />
    {register.error && <DataWarning title="Playbook register unavailable">{register.error}</DataWarning>}
    {canDraft && <Card title="Create draft" hint="Admin or super admin · AAL2 required · a different super admin must publish">
      <form action={createPlaybook} className="grid grid-cols-1 gap-4 md:grid-cols-4">
        <input type="hidden" name="operation_id" value={randomUUID()} />
        <label className="field-label">Region<input name="region_code" className="input mt-1" maxLength={20} required defaultValue="GLOBAL" /></label>
        <label className="field-label">Version<input type="number" name="version" className="input mt-1" min={1} max={100000} required defaultValue={1} /></label>
        <label className="field-label md:col-span-2">Title<input name="title" className="input mt-1" minLength={3} maxLength={160} required /></label>
        <label className="field-label md:col-span-4">Procedure text<textarea name="body_markdown" className="input mt-1 min-h-48" minLength={50} maxLength={12000} required placeholder="Activation criteria, incident roles, containment steps, communications, escalation, recovery, and close-out checks…" /></label>
        <div className="md:col-span-4"><button className="btn-primary" type="submit">Save immutable-version draft</button></div>
      </form>
    </Card>}
    <Card title="Version register" hint={`${register.data.length} latest versions · published version first`} padded={false}>
      {register.data.length === 0 ? <p className="p-5 text-sm text-ink-muted">No crisis playbook exists.</p> : <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Playbook</th><th>Integrity</th><th>Acknowledgement</th><th>Action</th></tr></thead><tbody>
        {register.data.map((item) => <tr key={item.playbook_id}>
          <td><p className="font-semibold text-burgundy">{item.title}</p><p className="text-xs text-ink-muted">{item.region_code} · version {item.version}</p><details className="mt-2 max-w-xl text-xs"><summary className="cursor-pointer text-warn">Read exact procedure</summary><pre className="mt-2 max-h-64 overflow-auto whitespace-pre-wrap rounded-md bg-canvas p-3 font-sans">{item.body_markdown}</pre></details></td>
          <td><Badge tone={item.status === "published" ? "ok" : item.status === "draft" ? "warn" : "neutral"}>{item.status}</Badge><p className="mt-1 max-w-40 truncate font-mono text-[10px] text-ink-muted" title={item.body_hash}>{item.body_hash}</p></td>
          <td><p className="text-xs">{Number(item.acknowledgement_count).toLocaleString()} staff</p><p className="text-[11px] text-ink-muted">{item.acknowledged_by_me ? "You acknowledged this hash" : "Not acknowledged by you"}</p></td>
          <td>{item.status === "draft" && isSuper ? <form action={publishPlaybook}><input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="playbook_id" value={item.playbook_id} /><button className="btn-secondary" type="submit">Publish version</button></form> : item.status === "published" && !item.acknowledged_by_me ? <form action={acknowledgePlaybook}><input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="playbook_id" value={item.playbook_id} /><button className="btn-primary" type="submit">Acknowledge exact hash</button></form> : <span className="text-xs text-ink-muted">No action required</span>}</td>
        </tr>)}
      </tbody></table></div>}
    </Card>
    <CapabilityNotice title="No silent edits">Once published, the title, region, version, procedure, and body hash cannot change. Revisions require a new version and independent publication; acknowledgement records bind staff to the exact published hash.</CapabilityNotice>
  </div>;
}
