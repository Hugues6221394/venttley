import Link from 'next/link';
import { randomUUID } from 'node:crypto';
import { OperatorPage,OperatorPanel,OperatorTable } from '@/components/ui/operator-workspace';
import { OperatorDrawer } from '@/components/ui/operator-controls';
import { QueueAttentionPanel } from '@/components/queue-attention-panel';
import { RefreshAttentionOnRender } from '@/components/staff-attention';
import { Badge } from '@/components/ui/badge';
import { WorkflowForm } from './workflow-form';
import { WorkflowUnavailable } from './daily-queues';
import { claimCaseWorkflow,decideCaseWorkflow,setCaseWorkflow } from '@/lib/daily-workflow-actions';
import type { CaseRow } from '@/app/(dashboard)/moderation/case-queue';

import {QueuePages,type QueuePagesProps} from './queue-pages';

const human=(s:string)=>s.replaceAll('_',' ');
const removable=new Set(['post','comment','whisper','tribe_message','dm_message']);

// Queue payloads deliberately omit evidence. Restricted reads remain explicit,
// separately authorized and audited in the existing case dossier workflow.
export function ModerationWorkflow({rows,resolved,error,pagination}:{rows:(Omit<CaseRow,'evidence'>&{updated_at:string})[];resolved:boolean;error:boolean;pagination:QueuePagesProps}) {
  return <OperatorPage title="Moderation queue" subtitle="Review cases, establish ownership and record a reasoned decision. Restricted evidence stays in its audited dossier." actions={<Link href="/moderation?tab=pending" prefetch={false} className="btn-secondary">Report-level tools</Link>}>
    <RefreshAttentionOnRender token={randomUUID()}/><QueueAttentionPanel queue="moderation"/>
    <form action="/moderation" className="workflow-filters"><label>Case state<select className="select" name="tab" defaultValue={resolved?'cases_resolved':'cases'}><option value="cases">Unresolved cases</option><option value="cases_resolved">Decided cases</option></select></label><button className="btn-secondary">Apply filters</button><Link href="/safety" prefetch={false}>Safety signals →</Link></form>
    {error?<WorkflowUnavailable message="Moderation cases could not be verified."/>:<OperatorPanel title="Case queue" hint={`${rows.length} cases on this page. Earliest deadline first; cases without a deadline are last.`}>
      {!rows.length?<p>No cases in this view.</p>:<OperatorTable caption="Moderation cases" headings={['Subject','Severity / state','Owner','Deadline','Review']}>
        {rows.map(row=><tr key={row.case_id}><th scope="row">{human(row.target_type)}<p className="operator-note">{row.report_count} reports{row.legal_hold?' · legal hold':''}</p></th><td><Badge tone={['critical','high'].includes(row.severity)?'danger':'neutral'}>{row.severity}</Badge><p>{human(row.status)}</p></td><td>{row.assignee_pseudonym?`@${row.assignee_pseudonym}`:'Unassigned'}</td><td>{row.sla_due_at?<><time dateTime={row.sla_due_at}>{new Date(row.sla_due_at).toISOString().slice(0,16).replace('T',' ')} UTC</time>{row.sla_breached&&<p className="operator-note">Overdue at queue read</p>}</>:'Not set'}</td><td>
          <OperatorDrawer title="Review moderation case" trigger="Review case">
            <section className="workflow-context"><h3>{human(row.target_type)} · {row.severity}</h3><p>{human(row.status)} · {row.report_count} reports</p><p>Owner: {row.assignee_pseudonym?`@${row.assignee_pseudonym}`:'Unassigned'}</p>{row.legal_hold&&<p>Legal hold is active. Existing retention controls still apply.</p>}<Link className="btn-secondary" href={`/moderation/cases/${row.case_id}`} prefetch={false}>Open audited case dossier</Link><p>Review the dossier before deciding. This queue does not reveal private-message bodies or restricted evidence.</p></section>
            {row.status!=='resolved'&&<>
              {!row.assignee_id&&<WorkflowForm action={claimCaseWorkflow} label="Assign to me" confirmation="Assign this case to your currently authenticated staff account. This does not resolve the case."><input type="hidden" name="operation_id" value={randomUUID()}/><input type="hidden" name="expected_updated_at" value={row.updated_at}/><input type="hidden" name="case_id" value={row.case_id}/></WorkflowForm>}
              <WorkflowForm action={setCaseWorkflow} label="Update workflow" confirmation="Record an internal workflow state and reason. Escalation does not contact external responders or grant extra permissions."><input type="hidden" name="operation_id" value={randomUUID()}/><input type="hidden" name="expected_updated_at" value={row.updated_at}/><input type="hidden" name="case_id" value={row.case_id}/><label>Next state<select name="status" className="select" defaultValue="awaiting_second_review"><option value="in_review">In review</option><option value="awaiting_second_review">Awaiting second review</option><option value="escalated">Escalated internally</option></select></label><label>Internal reason<textarea name="note" className="input" required rows={3} maxLength={500}/></label></WorkflowForm>
              <WorkflowForm action={decideCaseWorkflow} label="Record decision" confirmation="The existing moderation transaction records and carries out this decision. Verify the target and evidence first; account restrictions can affect the member's access."><input type="hidden" name="operation_id" value={randomUUID()}/><input type="hidden" name="expected_updated_at" value={row.updated_at}/><input type="hidden" name="case_id" value={row.case_id}/><label>Decision<select name="decision" className="select" defaultValue="no_action"><option value="no_action">No action</option>{removable.has(row.target_type)&&<option value="content_removed">Remove content</option>}{row.subject_id&&<><option value="user_warned">Warn member</option><option value="user_suspended">Suspend member</option><option value="user_shadow_restricted">Shadow-restrict member</option><option value="user_banned">Ban member permanently</option></>}</select></label><label>Policy code (optional)<input name="policy_code" className="input" maxLength={60}/></label><label>Decision reason<textarea name="note" className="input" required rows={4} maxLength={1000}/></label></WorkflowForm>
            </>}
            <details className="workflow-technical"><summary>Technical identifiers</summary><code>Case: {row.case_id}</code><code>Target: {row.target_id}</code></details>
          </OperatorDrawer>
        </td></tr>)}
      </OperatorTable>}
      <QueuePages {...pagination}/>
    </OperatorPanel>}
  </OperatorPage>;
}
