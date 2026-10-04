import Link from "next/link";
import { randomUUID } from "node:crypto";
import { readAccessReviews } from "@/lib/access-reviews";
import { commandAccessReview, createAccessReview } from "@/lib/access-review-actions";
import { reviewHref, type ReviewCampaign, type ReviewFilters, type ReviewItem } from "@/lib/access-review-model";
import { WorkflowForm } from "./workflow-form";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { DataWarning, CapabilityNotice } from "@/components/ui/operations";

const time=(value:string)=>`${new Date(value).toISOString().slice(0,16).replace("T"," ")} UTC`;
function Keys({campaign,item,command}:{campaign:ReviewCampaign;item?:ReviewItem;command:string}) {
  return <><input type="hidden" name="operation_id" value={randomUUID()}/><input type="hidden" name="campaign_id" value={campaign.campaign_id}/>
    <input type="hidden" name="version" value={item?.version??campaign.version}/><input type="hidden" name="command" value={command}/>
    {item&&<input type="hidden" name="subject_id" value={item.subject_id}/>}</>;
}

export async function AccessReviewRegister({filters}:{filters:ReviewFilters}) {
  const response=await readAccessReviews(filters);
  if(!response||!response.register.enabled)return <div className="flex flex-col gap-6">
    <PageHeader title="Staff access reviews" subtitle="Canonical review campaigns"/>
    <DataWarning title={!response?"Access-review register unavailable":"Access-review pilot disabled"}>No access certification can be inferred. The database workflow must be available and separately enabled before these controls can be used.</DataWarning>
    {!response&&<a className="btn-secondary" href={reviewHref(filters)}>Retry register</a>}
    <Link className="btn-secondary" href="/staff">Staff directory</Link></div>;
  const {register,reviewers}=response;
  const campaign=register.campaign,items=register.items?.slice(0,25)??[],campaigns=register.campaigns?.slice(0,25)??[];
  const nextItem=(register.items?.length??0)>25?items.at(-1)?.subject_id:null;
  const nextPeriod=(register.campaigns?.length??0)>25?campaigns.at(-1)?.period:null;
  return <div className="flex max-w-[1200px] flex-col gap-6">
    <PageHeader eyebrow="Governance" title="Staff access reviews" subtitle="Independent, time-bound decisions over a frozen staff scope. Review history is not proof of current Auth posture." actions={<Link className="btn-secondary" href="/staff">Staff controls</Link>}/>
    <p className="text-xs text-ink-muted">Snapshot taken {time(register.measured_at)}. Refresh the current record after changes.</p>
    {!campaign?<>
      <Card title="Start a periodic review" hint="Super admin · MFA required · up to 500 staff, never a truncated certification">
        <WorkflowForm action={createAccessReview} label="Create campaign" confirmation="Freeze the current staff scope. You review other accounts; a different active super admin is assigned your account. This grants no access." blockUncertainRetry>
          <input type="hidden" name="operation_id" value={randomUUID()}/>
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="field-label">Review month<input className="input mt-1" type="month" name="period" required defaultValue={new Date().toISOString().slice(0,7)}/></label>
            <label className="field-label">Due at (UTC)<input className="input mt-1" type="datetime-local" name="due_at" required defaultValue={new Date(Date.now()+7*86400000).toISOString().slice(0,16)}/></label>
          </div>
        </WorkflowForm>
      </Card>
      <Card title="Review campaigns" hint="Latest review months first; one campaign per month" padded={false}>
        {campaigns.length===0?<p className="p-5">No campaigns in this view.</p>:<ul className="divide-y divide-line">{campaigns.map(c=><li className="p-5" key={c.campaign_id}>
          <Link className="font-bold text-berry" href={reviewHref({campaign:c.campaign_id})}>Review {c.period.slice(0,7)}</Link>
          <p className="text-sm">Due {time(c.due_at)} · {c.closed_at?"Closed historical review":Date.parse(c.due_at)<Date.now()?"Overdue":"Open"}</p>
        </li>)}</ul>}
      </Card>
      {nextPeriod&&<Link href={reviewHref({before:nextPeriod})} prefetch={false}>Older campaigns</Link>}
      {filters.before&&<Link href={reviewHref()}>Latest campaigns</Link>}
    </>:<>
      <Card title={`Review ${campaign.period.slice(0,7)}`} hint={`Due ${time(campaign.due_at)}`}>
        <p>{campaign.closed_at?`Closed ${time(campaign.closed_at)}. Historical decisions may now be expired or access may have changed.`:"Open campaign. Closing requires every snapshot item to be resolved and current at closure."}</p>
        {register.totals&&<p className="mt-2 text-sm">{register.totals.total} in frozen scope · {register.totals.pending} pending · {register.totals.revocation_required} awaiting revocation · {register.totals.expired} expired attestations · {register.totals.changed} changed since snapshot</p>}
        {!campaign.closed_at&&<WorkflowForm action={commandAccessReview} label="Close campaign" confirmation="Close this historical review only after all items are resolved. The server rechecks role changes and expired attestations. No account is modified." blockUncertainRetry><Keys campaign={campaign} command="close"/></WorkflowForm>}
      </Card>
      {items.map(item=><Card key={item.subject_id} title={item.subject_name} hint={`${item.role_snapshot.replaceAll("_"," ")} · profile ${item.status_snapshot} · reviewer ${item.reviewer_name}`}>
        <Badge tone={item.decision==="revoke_required"||item.scope_changed?"warn":"neutral"}>{item.decision.replaceAll("_"," ")}</Badge>
        {item.scope_changed&&<p className="mt-2 text-sm">Account scope changed or the account was removed. Refresh the snapshot or verify completed revocation; do not attest the old scope.</p>}
        {item.valid_until&&<p className="mt-2 text-sm">Attestation {Date.parse(item.valid_until)<=Date.now()?"expired":"expires"} {time(item.valid_until)}. Expiry does not automatically revoke access.</p>}
        {!campaign.closed_at&&<>
          {item.assigned_to_me?<details className="mt-3"><summary className="cursor-pointer font-semibold">Review and act</summary>
            <div className="mt-3 grid gap-4 md:grid-cols-2">
              {!item.scope_changed&&<WorkflowForm action={commandAccessReview} label="Retain access" confirmation="Attest that this specific staff role is still needed. This records your review; it does not verify mailbox, MFA factors or sessions." blockUncertainRetry>
                <Keys campaign={campaign} item={item} command="retain"/>
                <label className="field-label">Valid until (UTC, maximum 90 days)<input className="input mt-1" type="datetime-local" name="valid_until" required/></label>
              </WorkflowForm>}
              {!item.scope_changed&&<WorkflowForm action={commandAccessReview} label="Require revocation" confirmation="Record that staff access must be removed. This does not revoke sessions or remove the role; a separate authorized action is required." blockUncertainRetry>
                <Keys campaign={campaign} item={item} command="require_revocation"/>
                <label className="field-label">Reason<select className="select mt-1" name="reason_code" required><option value="no_business_need">No business need</option><option value="inactive_access">Inactive access</option><option value="role_mismatch">Role mismatch</option></select></label>
              </WorkflowForm>}
              <WorkflowForm action={commandAccessReview} label="Confirm revoked access" confirmation="Verify from current database state that the subject no longer holds a staff role. This does not itself change access." blockUncertainRetry><Keys campaign={campaign} item={item} command="confirm_revoked"/></WorkflowForm>
              {item.scope_changed&&<WorkflowForm action={commandAccessReview} label="Refresh review scope" confirmation="Replace the old role/status snapshot with the current account state, clear the previous decision and require a new review. Prior events remain preserved." blockUncertainRetry><Keys campaign={campaign} item={item} command="refresh"/></WorkflowForm>}
            </div>
          </details>:<p className="mt-2 text-sm">Only the assigned independent reviewer can decide this item.</p>}
          {!item.is_self&&<details className="mt-3"><summary className="cursor-pointer">Change assigned reviewer</summary>
            <WorkflowForm action={commandAccessReview} label="Assign reviewer" confirmation="Assign a currently active super admin other than the subject. Assignment never adds permissions." blockUncertainRetry>
              <Keys campaign={campaign} item={item} command="reassign"/>
              <label className="field-label">Reviewer<select className="select mt-1" name="reviewer_id" required defaultValue=""><option value="" disabled>Select an eligible reviewer</option>{reviewers.filter(s=>s.staff_id!==item.subject_id).map(s=><option key={s.staff_id} value={s.staff_id}>{s.display_name} · @{s.username}</option>)}</select></label>
              <p className="text-xs text-ink-muted">Up to 100 active super admins shown. Eligibility is rechecked on save.</p>
            </WorkflowForm>
          </details>}
        </>}
      </Card>)}
      {nextItem&&<Link href={reviewHref({campaign:campaign.campaign_id,after:nextItem})} prefetch={false}>Next 25 staff</Link>}
      {filters.after&&<Link href={reviewHref({campaign:campaign.campaign_id})}>First staff page</Link>}
      <Card title="Recent review history" hint="Latest 20 immutable events; full history remains in the database">
        <ol>{register.events?.map(event=><li key={event.event_id} className="py-2 text-sm">{event.actor_name} · {event.subject_name} · {event.kind.replaceAll("_"," ")}{event.reason_code?` · ${event.reason_code.replaceAll("_"," ")}`:""} · {time(event.created_at)}</li>)}</ol>
      </Card>
      <Link href={reviewHref()}>All campaigns</Link>
    </>}
    <CapabilityNotice title="Explicit scope">The frozen review covers staff profile roles present at creation, not new hires, Auth factors, service keys or external systems. Revocation remains a separate MFA-protected staff action. Campaign creation is manual; automatic recurrence, escalation notifications and automatic removal on expiry are not enabled.</CapabilityNotice>
  </div>;
}
