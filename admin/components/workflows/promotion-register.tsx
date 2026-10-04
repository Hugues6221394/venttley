import Link from "next/link";
import { randomUUID } from "node:crypto";
import { readPromotions } from "@/lib/promotions";
import { requestPromotion, commandPromotion } from "@/lib/promotion-actions";
import { promotionHref, type promotionFilters, type PromotionItem } from "@/lib/promotion-model";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { DataWarning, CapabilityNotice } from "@/components/ui/operations";
import { WorkflowForm } from "./workflow-form";

const utc=(date:string)=>new Date(date).toISOString().replace("T"," ").replace("Z"," UTC");
function Command({item,command}:{item:PromotionItem;command:"approve"|"reject"|"cancel"|"execute"}) {
  const copy={approve:"Approve promotion",reject:"Reject request",cancel:"Cancel request",execute:"Execute approved promotion"};
  return <WorkflowForm action={commandPromotion} label={copy[command]} blockUncertainRetry
    confirmation={command==="execute"?"Promote only the approved target to super admin. The server rechecks both operators, target authority, MFA readiness and expiry, then revokes the target's sessions and records execution atomically.":`${copy[command]}? This records a decision; it does not change any role. Approval requires a different operator from the requester and target.`}>
    <input type="hidden" name="operation_id" value={randomUUID()} />
    <input type="hidden" name="approval_id" value={item.approval_id} />
    <input type="hidden" name="version" value={item.version} />
    <input type="hidden" name="command" value={command} />
  </WorkflowForm>;
}
export async function PromotionRegister({filters}:{filters:NonNullable<ReturnType<typeof promotionFilters>>}) {
  const result=await readPromotions(filters);
  const items=result?.register.enabled?result.register.items.slice(0,25):[];
  const next=result?.register.enabled&&result.register.items.length>25?items.at(-1):undefined;
  return <div className="flex max-w-[1200px] flex-col gap-6">
    <PageHeader eyebrow="Governance" title="Sensitive approvals" subtitle="Super-admin promotions only. One requester and one independent approver, both at AAL2; approval is not execution." actions={<Link href="/staff" className="btn-secondary">Staff directory</Link>}/>
    {!result?<DataWarning title="Approval data unavailable">The queue is unknown, not empty. Reload to retry. Do not use direct role changes to work around an outage.</DataWarning>
      :!result.register.enabled?<DataWarning title="Promotion approval enforcement is disabled">The deployment owner must verify and separately enable the database control. This interface does not establish protection while that control is off.</DataWarning>:<>
      <p className="text-xs text-ink-muted">Snapshot {utc(result.register.measured_at)} · 25 requests per page · decisions expire 24 hours after creation.</p>
      <div className="grid gap-4 sm:grid-cols-3">{["pending","approved","executed"].map(state=><Card key={state}><p className="h-eyebrow">{state} · this page{state!=="executed"?" · unexpired":""}</p><p className="mt-2 text-3xl font-extrabold text-burgundy">{items.filter(i=>i.state===state&&(state==="executed"||!i.expired)).length}</p></Card>)}</div>
      {!filters.source&&<Card title="Request a super-admin promotion" hint="Only existing active staff with confirmed email, completed invitation setup and verified MFA are eligible.">
        <form method="get" action="/approvals" className="mb-4 flex flex-wrap items-end gap-3">
          <label className="field-label">Staff username prefix<input className="input mt-1" name="q" pattern="[A-Za-z0-9_]*" maxLength={24} defaultValue={filters.query}/></label>
          <button className="btn-secondary" type="submit">Find staff</button>
        </form>
        {result.candidatesUnavailable?<DataWarning title="Staff selector unavailable">No empty eligible-staff list is inferred. Refresh to retry.</DataWarning>:<>
          {result.candidates.length>25&&<p className="mb-3 text-xs text-ink-muted">More staff match. Narrow the username prefix to find someone outside this first 25.</p>}
          <WorkflowForm action={requestPromotion} label="Request independent approval" disabled={result.candidates.length===0} blockUncertainRetry confirmation="Request super-admin authority for the selected staff member. A different current super admin must approve; you must then explicitly execute before expiry. No role changes now.">
            <input type="hidden" name="operation_id" value={randomUUID()}/>
            <label className="field-label">Staff member<select className="select mt-1" name="target_id" required defaultValue=""><option value="" disabled>Select eligible staff</option>{result.candidates.slice(0,25).map(c=><option key={c.user_id} value={c.user_id}>{c.display_name} · @{c.username} · {c.role.replaceAll("_"," ")}</option>)}</select></label>
            <label className="field-label">Business purpose<select className="select mt-1" name="reason_code" required><option value="operational_coverage">Operational coverage</option><option value="succession">Succession</option><option value="security_oversight">Security oversight</option></select></label>
          </WorkflowForm>
          {result.candidates.length===0&&<p className="mt-3 text-xs text-ink-muted">No eligible staff match this prefix. Normal members and pending invitations cannot be promoted through this workflow.</p>}
        </>}
      </Card>}
      <Card title="Promotion requests" hint="The server rechecks current authority at each action. These counts are not global actionable-work badges." padded={false}>
        {items.length===0?<p className="p-5 text-sm text-ink-muted">{filters.source?"This request is unavailable. No other request has been substituted.":"No requests on this page."}</p>:<ul className="divide-y divide-line">{items.map(item=><li key={item.approval_id} className="space-y-3 p-5">
          <div className="flex flex-wrap gap-2"><h2 className="font-bold text-ink">{item.target_name}</h2><Badge>{item.state}</Badge>{item.expired&&["pending","approved"].includes(item.state)&&<Badge tone="warn">Expired · not executable</Badge>}</div>
          <p className="text-sm">{item.target_role.replaceAll("_"," ")} → super admin · {item.reason_code.replaceAll("_"," ")}</p>
          <ol className="space-y-1 text-xs text-ink-muted" aria-label="Approval history">
            <li>Requested by {item.requester_name} · {utc(item.created_at)}</li>
            <li>{item.approved_at?`Approved by ${item.approver_name??"Former staff"} · ${utc(item.approved_at)}`:"No approval recorded"}</li>
            <li>{item.executed_at?`Executed ${utc(item.executed_at)}`:`Expires ${utc(item.expires_at)}`}</li>
          </ol>
          {["pending","approved"].includes(item.state)&&<div className="grid gap-4 md:grid-cols-2">
            {item.state==="pending"&&!item.expired&&!item.requested_by_me&&!item.targets_me&&<Command item={item} command="approve"/>}
            {item.state==="pending"&&!item.requested_by_me&&!item.targets_me&&<Command item={item} command="reject"/>}
            {item.state==="approved"&&!item.expired&&item.requested_by_me&&<Command item={item} command="execute"/>}
            <Command item={item} command="cancel"/>
          </div>}
          <details className="text-xs text-ink-muted"><summary>Technical reference</summary><code className="break-all">{item.approval_id}</code></details>
        </li>)}</ul>}
      </Card>
      {next&&<Link href={promotionHref(next)} className="btn-secondary" prefetch={false}>Older requests</Link>}
    </>}
    <a className="btn-secondary" href="/approvals">Reload first page</a>
    <CapabilityNotice title="Scoped rollout, not universal approval coverage">This pilot covers super-admin promotions only. Global broadcast approvals have a separate gated workflow at /broadcasts. Deletions, exports and kill switches still need action-bound execution contracts. Database enforcement remains enabled if this UI is hidden; only the privileged deployment control can disable it, with a retained control record.</CapabilityNotice>
  </div>;
}
