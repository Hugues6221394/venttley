import Link from 'next/link';
import { randomUUID } from 'node:crypto';
import { OperatorPage, OperatorPanel, OperatorTable } from '@/components/ui/operator-workspace';
import { OperatorDrawer } from '@/components/ui/operator-controls';
import { QueueAttentionPanel } from '@/components/queue-attention-panel';
import { RefreshAttentionOnRender } from '@/components/staff-attention';
import { WorkflowForm } from './workflow-form';
import { Badge } from '@/components/ui/badge';
import { decideAppealWorkflow,reviewSafetyWorkflow } from '@/lib/daily-workflow-actions';
import type { AppealRow } from '@/app/(dashboard)/appeals/page';
import type { SafetyRow } from '@/app/(dashboard)/safety/page';

import {QueuePages,type QueuePagesProps} from './queue-pages';

const human=(s:string)=>s.replaceAll('_',' ');
function TechnicalDetails({id}:{id:string}){return <details className="workflow-technical"><summary>Technical identifier</summary><code>{id}</code></details>;}
export function WorkflowUnavailable({message}:{message:string}) {
  return <div className="workflow-result is-error" role="status"><h2>Queue unavailable</h2><p>{message} Reload this page to retry. No empty or healthy state is inferred.</p></div>;
}
export function AppealWorkflow({rows,tab,error,pagination}:{rows:AppealRow[];tab:string;error:boolean;pagination:QueuePagesProps}) {
  return <OperatorPage title="Appeals review" subtitle="Review contested decisions independently. Explanations are sent to the member; choose them with care.">
    <RefreshAttentionOnRender token={randomUUID()}/><QueueAttentionPanel queue="appeals"/>
    <form className="workflow-filters" action="/appeals"><label>Status<select className="select" name="tab" defaultValue={tab}>{['open','upheld','overturned','all'].map(s=><option key={s} value={s}>{human(s)}</option>)}</select></label><button className="btn-secondary">Apply filters</button></form>
    {error?<WorkflowUnavailable message="Appeals could not be verified."/>:<OperatorPanel title="Appeal queue" hint={`${rows.length} appeals on this page. Oldest first; use Next page for more.`}>
      {!rows.length?<p>No appeals in this view.</p>:<OperatorTable caption="Appeals" headings={['Subject','Original decision','State','Filed','Review']}>
        {rows.map(row=><tr key={row.appeal_id}><th scope="row">{human(row.subject_kind)}<p className="operator-note">@{row.appellant_pseudonym??'unknown'}</p></th><td>{human(row.original_decision??'Not recorded')}</td><td><Badge tone={row.status==='open'?'warn':'neutral'}>{row.status}</Badge></td><td><time dateTime={row.created_at}>{new Date(row.created_at).toISOString().slice(0,10)}</time></td>
          <td><OperatorDrawer title="Independent appeal review" trigger="Review appeal"><Badge tone="neutral">{row.status}</Badge>
            <section className="workflow-context"><h3>Member statement</h3><p>{row.statement}</p></section>
            <section className="workflow-context"><h3>Original decision</h3><p>{human(row.original_decision??'Not recorded')}</p><p>{row.original_note??'No reason was recorded.'}</p><p>Decided by @{row.original_decider_pseudonym??'unknown'}</p>{row.case_id&&<Link href={`/moderation/cases/${row.case_id}`} prefetch={false}>Open exact case dossier →</Link>}</section>
            {row.status==='open'&&row.reviewable_by_me?<WorkflowForm action={decideAppealWorkflow} label="Record outcome" confirmation="This records an independent decision and sends your explanation to the member. Overturning may restore content or account access; a verification refusal reopens review, not a badge grant.">
              <input type="hidden" name="operation_id" value={randomUUID()}/><input type="hidden" name="appeal_id" value={row.appeal_id}/><label>Outcome<select className="select" name="outcome"><option value="upheld">Uphold decision</option><option value="overturned">Overturn decision</option></select></label><label>Member-facing explanation<textarea name="note" className="input" required maxLength={1000} rows={4}/></label>
            </WorkflowForm>:<p>{row.status==='open'?'An independent moderator must review this appeal. You took the original decision or are its appellant.':'This appeal already has an outcome.'}</p>}
            <TechnicalDetails id={row.appeal_id}/>
          </OperatorDrawer></td></tr>)}
      </OperatorTable>}
      <QueuePages {...pagination}/>
    </OperatorPanel>}
  </OperatorPage>;
}
const safetyKinds:Record<string,string>={crisis_post:'post',crisis_whisper:'whisper',crisis_tribe_message:'tribe_message',crisis_dm:'chat_message',self_harm_report:'report'};
export function SafetyWorkflow({items,includeResolved,error,canReview,pagination}:{items:SafetyRow[];includeResolved:boolean;error:boolean;canReview:boolean;pagination:QueuePagesProps}) {
  return <OperatorPage title="Safety & crisis" subtitle="Signals need human review. Reviewing a signal is not proof that a member is safe or that emergency help was dispatched.">
    <RefreshAttentionOnRender token={randomUUID()}/>
    <div className="workflow-notice"><strong>Follow the approved regional response process.</strong><p>Keep restricted evidence in its audited workflow. Do not paste member content into notes, external design tools or analytics.</p><Link href="/crisis/playbooks" prefetch={false}>Open crisis playbooks →</Link></div>
    <form className="workflow-filters" action="/safety"><label>View<select className="select" name="show" defaultValue={includeResolved?'resolved':'open'}><option value="open">Open signals</option><option value="resolved">Include resolved signals</option></select></label><button className="btn-secondary">Apply filters</button></form>
    {error?<WorkflowUnavailable message="Safety signals could not be verified."/>:<OperatorPanel title="Safety signals" hint={`${items.length} signals on this page. Open signals, highest severity and oldest first. Response targets are guidance, not a measured response or dispatch receipt.`}>
      {!items.length?<p>No signals in this view. This is not a guarantee that every risk was detected.</p>:<OperatorTable caption="Safety signals" headings={['Signal','Severity','State','Raised','Review']}>
        {items.map(row=><tr key={`${row.item_type}-${row.ref_id}`}><th scope="row">{human(row.item_type)}<p className="operator-note">{row.severity==='high'?'15 minute':'60 minute'} review target</p></th><td><Badge tone={row.severity==='high'?'danger':'warn'}>{row.severity}</Badge></td><td>{row.is_open?'Needs review':'Reviewed / handled'}</td><td><time dateTime={row.created_at}>{new Date(row.created_at).toISOString().slice(0,16).replace('T',' ')} UTC</time></td>
          <td><OperatorDrawer title="Review safety signal" trigger="View signal"><p>Potential risk, not a confirmed incident.</p>{row.preview&&<section className="workflow-context"><h3>Authorized preview</h3><p>{row.preview}</p></section>}{row.note&&<section className="workflow-context"><h3>Reporter note</h3><p>{row.note}</p></section>}
            {row.is_open&&canReview&&safetyKinds[row.item_type]&&<WorkflowForm action={reviewSafetyWorkflow} label="Record review" confirmation="This clears the crisis flag or marks the report handled. Record only a completed review; this does not contact a responder or verify the member is safe."><input type="hidden" name="operation_id" value={randomUUID()}/><input name="kind" type="hidden" value={safetyKinds[row.item_type]}/><input name="ref_id" type="hidden" value={row.item_type==='self_harm_report'?row.report_id??row.ref_id:row.ref_id}/><label>Review reason<textarea className="input" name="note" rows={3} required maxLength={500}/></label></WorkflowForm>}
            {!canReview&&<p>Your role can read this queue. A moderator must record the review.</p>}
            <Link href="/moderation" prefetch={false}>Open moderation →</Link><TechnicalDetails id={row.ref_id}/>
          </OperatorDrawer></td></tr>)}
      </OperatorTable>}
      <QueuePages {...pagination}/>
    </OperatorPanel>}
  </OperatorPage>;
}
