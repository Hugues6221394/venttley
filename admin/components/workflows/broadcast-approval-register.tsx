import Link from "next/link";
import { randomUUID } from "node:crypto";
import { readBroadcastApprovals } from "@/lib/broadcast-approvals";
import { requestBroadcastApproval, commandBroadcastApproval, stopApprovedBroadcast } from "@/lib/broadcast-approval-actions";
import { broadcastApprovalHref, type BroadcastApproval } from "@/lib/broadcast-approval-model";
import type { BroadcastApprovalCursor } from "@/lib/broadcast-approval-model";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { DataWarning, CapabilityNotice } from "@/components/ui/operations";
import { WorkflowForm } from "./workflow-form";

const utc=(value:string)=>new Date(value).toISOString().replace("T"," ").replace("Z"," UTC");
function Command({item,command}:{item:BroadcastApproval;command:"approve"|"reject"|"cancel"|"publish"|"stop"}) {
  const labels={approve:"Approve exact message",reject:"Reject request",cancel:"Cancel request",publish:"Publish approved message",stop:"Deactivate broadcast"};
  const confirmation=command==="publish"
    ?"Publish the reviewed message for everyone, immediately, until its displayed expiry? The server rechecks authority, approval and expiry. This does not establish delivery to devices."
    :command==="stop"?"Deactivate this broadcast? Previously delivered or downloaded content cannot be recalled."
    :`${labels[command]}? This records your decision without publishing. Changing the message requires cancelling and submitting a new request.`;
  return <WorkflowForm action={command==="stop"?stopApprovedBroadcast:commandBroadcastApproval} label={labels[command]} confirmation={confirmation} blockUncertainRetry>
    <input type="hidden" name="operation_id" value={randomUUID()}/>
    <input type="hidden" name="approval_id" value={item.approval_id}/>
    <input type="hidden" name="version" value={item.version}/>
    <input type="hidden" name="command" value={command}/>
  </WorkflowForm>;
}
export async function BroadcastApprovalRegister({cursor,superAdmin}:{cursor:BroadcastApprovalCursor;superAdmin:boolean}) {
  const result=await readBroadcastApprovals(cursor);
  const items=result?.enabled?result.items.slice(0,25):[];
  const next=result?.enabled&&result.items.length>25?items.at(-1):undefined;
  return <div className="flex max-w-[1200px] flex-col gap-6">
    <PageHeader eyebrow="Platform operations" title="Broadcast approvals" subtitle="Draft → independent review → explicit publication. Immediate global messages only; no targeted or scheduled sends." actions={superAdmin?<Link href="/approvals" className="btn-secondary">Approval controls</Link>:undefined}/>
    {!result?<DataWarning title="Broadcast approvals unavailable">The queue is unknown, not empty. Reload to retry. Do not use a direct send to work around the outage.</DataWarning>
    :!result.enabled?<DataWarning title="Database approval enforcement is disabled">The deployment owner must verify and enable the database control separately. This page does not establish protection while enforcement is off.</DataWarning>:<>
      <p className="text-xs text-ink-muted">Snapshot {utc(result.measured_at)} · 25 requests per page · approval expires after 24 hours or at message expiry, whichever comes first.</p>
      <div className="grid gap-4 sm:grid-cols-3">{["pending","approved","published"].map(state=><Card key={state}>
        <p className="h-eyebrow">{state} · this page{state!=="published"?" · unexpired":" · publication records"}</p>
        <p className="mt-2 text-3xl font-extrabold text-burgundy">{items.filter(i=>i.state===state&&(state==="published"||!i.expired)).length}</p>
      </Card>)}</div>
      {!cursor.source&&<Card title="Draft a global broadcast" hint="No private member content, identifying data or secrets. Both the requester and independent super-admin reviewer must complete MFA.">
        <WorkflowForm action={requestBroadcastApproval} label="Submit for review" blockUncertainRetry confirmation="Store this exact draft for an independent super admin to review? This does not publish. To change it later, cancel it and submit a new request.">
          <input type="hidden" name="operation_id" value={randomUUID()}/>
          <label className="field-label">Title<input className="input mt-1" name="title" required maxLength={120}/></label>
          <label className="field-label">Message<textarea className="textarea mt-1" name="body" required maxLength={1000} rows={5}/></label>
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="field-label">Urgency<select className="select mt-1" name="urgency"><option value="info">Information</option><option value="warning">Warning</option><option value="critical">Critical</option><option value="crisis">Crisis</option></select></label>
            <label className="field-label">Message expiry (UTC)<input className="input mt-1" type="datetime-local" name="expires_at" required aria-describedby="broadcast-expiry-hint"/></label>
          </div>
          <p id="broadcast-expiry-hint" className="text-xs text-ink-muted">Must be within seven days. Everyone is the fixed audience. Publication is immediate only after explicit execution by the requester.</p>
        </WorkflowForm>
      </Card>}
      <Card title="Review queue and publication records" hint="Review the exact message and UTC expiry. Reading or approving does not publish." padded={false}>
        {items.length===0?<p className="p-5 text-sm text-ink-muted">{cursor.source?"This request is unavailable. No other request has been substituted.":"No requests on this page."}</p>:<ul className="divide-y divide-line">{items.map(item=><li key={item.approval_id} className="space-y-4 p-5">
          <div className="flex flex-wrap items-center gap-2"><Badge>{item.state}</Badge><Badge tone={item.urgency==="info"?"neutral":"warn"}>{item.urgency}</Badge>
            {item.expired&&["pending","approved"].includes(item.state)&&<Badge tone="warn">Expired · cannot publish</Badge>}
            {item.state==="published"&&<Badge>{item.publication_active===null?"Publication unavailable":!item.publication_active?"Deactivated":new Date(item.publication_expires_at).getTime()<=Date.now()?"Message expired":"Active publication"}</Badge>}
          </div>
          <section aria-label="Exact broadcast preview" className="workflow-context">
            <p className="h-eyebrow">Global message preview · everyone</p>
            <h2 className="mt-2 break-words font-bold text-ink">{item.title}</h2>
            <p className="mt-2 whitespace-pre-wrap break-words text-sm text-ink">{item.body}</p>
            <p className="mt-3 text-xs text-ink-muted">Message expires {utc(item.publication_expires_at)}</p>
          </section>
          <ol className="space-y-1 text-xs text-ink-muted" aria-label="Approval history">
            <li>Requested by {item.requester_name} · {utc(item.created_at)}</li>
            <li>{item.approved_at?`Approved by ${item.approver_name??"Former staff"} · ${utc(item.approved_at)}`:"No approval recorded"}</li>
            <li>{item.published_at?`Published ${utc(item.published_at)} · device delivery unverified`:`Approval deadline ${utc(item.expires_at)}`}</li>
          </ol>
          {["pending","approved"].includes(item.state)&&<div className="grid gap-4 md:grid-cols-2">
            {superAdmin&&item.state==="pending"&&!item.requested_by_me&&!item.expired&&<Command item={item} command="approve"/>}
            {superAdmin&&item.state==="pending"&&!item.requested_by_me&&<Command item={item} command="reject"/>}
            {item.state==="approved"&&item.requested_by_me&&!item.expired&&<Command item={item} command="publish"/>}
            {(superAdmin||item.requested_by_me)&&<Command item={item} command="cancel"/>}
          </div>}
          {item.state==="published"&&item.publication_active===true&&<Command item={item} command="stop"/>}
          <details className="text-xs text-ink-muted"><summary>Technical reference</summary><code className="break-all">{item.approval_id}</code></details>
        </li>)}</ul>}
      </Card>
      {next&&<Link href={broadcastApprovalHref(next)} className="btn-secondary" prefetch={false}>Older requests</Link>}
    </>}
    <a href="/broadcasts" className="btn-secondary">Reload first page</a>
    <CapabilityNotice title="Publication is not delivery evidence">This pilot does not send push notifications or prove mobile banner delivery. Staff approval notices require a separate verified rollout. Global queue badges, targeted audiences and scheduling remain separate work. Only requests created through this workflow appear here. Hide the pilot UI to return to the legacy publication register, including emergency deactivation; hiding it does not disable database enforcement.</CapabilityNotice>
  </div>;
}
