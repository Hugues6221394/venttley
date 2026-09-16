import { randomUUID } from "node:crypto";
import { createLegalRequest, decideLegalRequest, fulfilLegalRequest } from "./actions";
import { OperationResult } from "@/components/operation-result";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { getLegalRequests, getOperationalRole } from "@/lib/governance";

export const dynamic = "force-dynamic";

export default async function LegalRequestsPage({ searchParams }: { searchParams: Promise<{ result?: string }> }) {
  const [{ result }, queue, role] = await Promise.all([searchParams, getLegalRequests(), getOperationalRole()]);
  const isSuper = role === "super_admin";
  const dueDefault = new Date(Date.now() + 7 * 86_400_000).toISOString().slice(0, 16);
  return <div className="flex max-w-[1500px] flex-col gap-6">
    <PageHeader eyebrow="Legal & privacy" title="Legal requests" subtitle="Hashed-reference intake with two-person approval and completion evidence. This register never stores the request document or disclosed user content." />
    <OperationResult code={result} />
    {queue.error && <DataWarning title="Legal register unavailable">{queue.error}</DataWarning>}
    <Card title="Register request" hint="Admin or super admin · AAL2 required · hash the external reference before entry">
      <form action={createLegalRequest} className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <input type="hidden" name="operation_id" value={randomUUID()} />
        <label className="field-label">Request type<select name="request_type" className="input mt-1" defaultValue="law_enforcement"><option value="law_enforcement">Law enforcement</option><option value="court_order">Court order</option><option value="preservation">Preservation</option><option value="privacy_regulator">Privacy regulator</option><option value="emergency">Emergency</option><option value="other">Other</option></select></label>
        <label className="field-label">Jurisdiction code<input name="jurisdiction" className="input mt-1" maxLength={16} required placeholder="RW, EU, US-CA" /></label>
        <label className="field-label">Due at<input type="datetime-local" name="due_at" className="input mt-1" required defaultValue={dueDefault} /></label>
        <label className="field-label md:col-span-2">External reference SHA-256<input name="reference_hash" className="input mt-1 font-mono" minLength={64} maxLength={64} required autoComplete="off" /></label>
        <label className="field-label">Scope<select name="scope_code" className="input mt-1" defaultValue="account_metadata"><option value="account_metadata">Account metadata</option><option value="content_preservation">Content preservation</option><option value="account_disclosure">Account disclosure</option><option value="platform_statistics">Platform statistics</option><option value="emergency_request">Emergency request</option></select></label>
        <div className="md:col-span-3"><button className="btn-primary" type="submit">Register request</button></div>
      </form>
    </Card>
    <Card title="Request register" hint={`${queue.data.length} most recent · due date first`} padded={false}>
      {queue.data.length === 0 ? <p className="p-5 text-sm text-ink-muted">No legal request is registered.</p> : <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Request</th><th>Authority</th><th>Evidence</th><th>Controlled action</th></tr></thead><tbody>
        {queue.data.map((item) => {
          const undecided = ["received", "validating", "counsel_review", "awaiting_approval"].includes(item.status);
          return <tr key={item.legal_request_id}>
            <td><p className="font-semibold text-burgundy">{item.request_type.replaceAll("_", " ")}</p><p className="text-xs text-ink-muted">{item.scope_code.replaceAll("_", " ")} · due {new Date(item.due_at).toLocaleString()}</p><p className="font-mono text-[10px] text-ink-muted">{item.legal_request_id}</p></td>
            <td><p className="text-xs font-semibold">{item.jurisdiction}</p><Badge tone={item.status === "rejected" ? "danger" : item.status === "fulfilled" ? "ok" : "warn"}>{item.status.replaceAll("_", " ")}</Badge></td>
            <td className="text-xs"><p>Requester {item.requester_verified ? "verified" : "not verified"}</p><p>Manifest {item.manifest_recorded ? "recorded" : "missing"}</p><p>Receipt {item.completion_recorded ? "recorded" : "missing"}</p></td>
            <td>{isSuper && undecided ? <form action={decideLegalRequest} className="grid min-w-[510px] grid-cols-2 gap-2">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="request_id" value={item.legal_request_id} />
              <label className="field-label">Decision<select name="decision" className="select mt-1" defaultValue="approve"><option value="approve">Approve</option><option value="reject">Reject</option></select></label>
              <label className="field-label">Reason<select name="reason_code" className="select mt-1" defaultValue="valid_authority"><option value="valid_authority">Valid authority</option><option value="emergency_authority">Emergency authority</option><option value="invalid_authority">Invalid authority</option><option value="insufficient_scope">Insufficient scope</option><option value="withdrawn">Withdrawn</option></select></label>
              <label className="field-label col-span-2">Disclosure manifest SHA-256<input name="manifest_hash" className="input mt-1 font-mono" maxLength={64} placeholder="Required for approval" /></label>
              <label className="col-span-2 flex items-center gap-2 text-xs"><input type="checkbox" name="requester_verified" /> I independently verified the requester&apos;s authority.</label>
              <div className="col-span-2"><button className="btn-secondary" type="submit">Record decision</button></div>
            </form> : isSuper && item.status === "approved" ? <form action={fulfilLegalRequest} className="flex min-w-[420px] items-end gap-2">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="request_id" value={item.legal_request_id} />
              <label className="field-label grow">Completion receipt SHA-256<input name="receipt_hash" className="input mt-1 font-mono" minLength={64} maxLength={64} required /></label><button className="btn-secondary" type="submit">Record fulfilment</button>
            </form> : <span className="text-xs text-ink-muted">{isSuper ? "No action available" : "Super admin approval required"}</span>}</td>
          </tr>;
        })}
      </tbody></table></div>}
    </Card>
    <CapabilityNotice title="Disclosure remains deliberately external">This workflow authorizes and audits a disclosure; it does not generate or transmit exports. Actual disclosure packaging still requires a separately reviewed, recipient-bound delivery system with data minimization and receipt verification.</CapabilityNotice>
  </div>;
}
