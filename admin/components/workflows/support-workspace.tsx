import Link from 'next/link';
import { Suspense } from 'react';
import { SupportHistory } from './support-history';
import { SupportBindings } from './support-bindings';
import { randomUUID } from 'node:crypto';
import { OperatorPage,OperatorPanel,OperatorTable } from '@/components/ui/operator-workspace';
import { OperatorDrawer } from '@/components/ui/operator-controls';
import { QueueAttentionPanel } from '@/components/queue-attention-panel';
import { RefreshAttentionOnRender } from '@/components/staff-attention';
import { WorkflowForm } from './workflow-form';
import { SupportStaffSelector } from './staff-selector';
import { WorkflowUnavailable } from './daily-queues';
import { supportWorkQueue } from '@/lib/workflows';
import { getLinkedQueue,type SupportCase } from '@/lib/governance';
import { supportStates,supportPriorities,supportQueueHref } from '@/lib/workflow-model';
import { createSupportWorkflow,saveSupportWorkflow } from '@/lib/daily-workflow-actions';
import { Badge } from '@/components/ui/badge';

const human=(s:string)=>s.replaceAll('_',' ');
const stamp=(s:string)=>new Date(s).toISOString().slice(0,16).replace('T',' ')+' UTC';
function CreateCase() {
  return <OperatorDrawer title="Create support case" trigger="Create case"><p>Metadata only. Do not paste confessions, private messages or personal contact details.</p>
    <WorkflowForm action={createSupportWorkflow} label="Create support case" confirmation="Create a metadata-only support case with the selected category and priority. The server validates any source binding and requires MFA.">
      <input type="hidden" name="operation_id" value={randomUUID()}/>
      <label>Category<select className="select" name="category" defaultValue="technical">{['access','appeal_help','verification_help','privacy_request','recovery_help','safety_followup','technical','other'].map(s=><option key={s} value={s}>{human(s)}</option>)}</select></label>
      <label>Priority<select className="select" name="priority" defaultValue="normal">{supportPriorities.map(s=><option key={s} value={s}>{s}</option>)}</select></label>
      <SupportBindings/>
    </WorkflowForm>
  </OperatorDrawer>;
}
export async function SupportWorkspace({params}:{params:Record<string,string|undefined>}) {
  const [queue,detail]=await Promise.all([
    supportWorkQueue(params),params.source?getLinkedQueue<SupportCase>('support','all',params.source).catch(()=>({data:[] as SupportCase[],error:'Unavailable'})):Promise.resolve(null),
  ]);
  const row=detail?.data[0],first=queue.filters?supportQueueHref(queue.filters):'/support/cases';
  const base=queue.filters?supportQueueHref(queue.filters,queue.filters.afterDue&&queue.filters.afterId?{sla_due_at:queue.filters.afterDue,support_case_id:queue.filters.afterId}:undefined):first;
  return <OperatorPage title="Support cases" subtitle="Find, assign and resolve metadata-only cases. Ownership and deadlines stay visible; private content stays in its source system." actions={<CreateCase/>}>
    <RefreshAttentionOnRender token={randomUUID()}/><QueueAttentionPanel queue="support"/>
    <form className="workflow-filters" action="/support/cases"><label>Queue<select className="select" name="queue" defaultValue={queue.filters?.queue??'open'}>{['open','all','resolved','closed'].map(s=><option key={s} value={s}>{s}</option>)}</select></label><label>Owner<select className="select" name="owner" defaultValue={queue.filters?.owner??'all'}><option value="all">All owners</option><option value="mine">Assigned to me</option><option value="unassigned">Unassigned</option></select></label><label>Priority<select className="select" name="priority" defaultValue={queue.filters?.priority??'all'}>{['all',...supportPriorities].map(s=><option key={s} value={s}>{s}</option>)}</select></label><button className="btn-secondary">Apply filters</button><Link href="/support/cases" prefetch={false}>Reset</Link></form>
    <div className={row?'workflow-columns':''}>
      {queue.error?<WorkflowUnavailable message={queue.error}/>:<OperatorPanel title="Case queue" hint={`${queue.data.length} rows on this page, not total backlog. Earliest deadline first; follow Next for more.`}>
        {!queue.data.length?<p>No cases in this view.</p>:<OperatorTable caption="Support cases" headings={['Case','State','Owner / deadline','Open']}>
          {queue.data.map(item=><tr key={item.support_case_id}><th scope="row">{item.subject||human(item.category)}<p className="operator-note">{item.last_message_by==='member'&&!['resolved','closed'].includes(item.status)?'Awaiting reply · ':''}{human(item.source_kind)}</p></th><td><Badge tone={item.priority==='critical'?'danger':'neutral'}>{item.priority}</Badge><p>{human(item.status)}</p></td><td>{item.assignee_name??'Unassigned'}<p className="operator-note"><time dateTime={item.sla_due_at}>{stamp(item.sla_due_at)}</time></p></td><td><Link className="btn-secondary" prefetch={false} href={`${base}&source=${item.support_case_id}`}>Open case</Link></td></tr>)}
        </OperatorTable>}
        <nav className="operator-actions" aria-label="Support queue pages">{queue.filters?.afterId&&<Link href={first} prefetch={false} className="btn-secondary">First page</Link>}{queue.next&&queue.filters&&<Link href={supportQueueHref(queue.filters,queue.next)} prefetch={false} className="btn-secondary">Next page</Link>}</nav>
      </OperatorPanel>}
      {params.source&&(detail?.error||!row)?<WorkflowUnavailable message="The selected case is unavailable or no longer accessible."/>:row&&<OperatorPanel title={human(row.category)} hint="Selected case · changing queue filters or navigating away discards unsaved inputs.">
        <Link href={base} prefetch={false}>Close detail</Link><Link href={`/support/cases/${row.support_case_id}`} prefetch={false} className="btn-primary">Open conversation</Link><section className="workflow-context"><h3>Current state</h3><p>{human(row.status)} · {row.priority} priority</p><p>Owner: {row.assignee_name??'Unassigned'}</p><p>Due {stamp(row.sla_due_at)}</p><p>Updated {stamp(row.updated_at)}</p><p>Changing priority does not recalculate the existing deadline.</p></section>
        <OperatorDrawer title="Update support case" trigger="Edit case"><WorkflowForm action={saveSupportWorkflow} label="Save case" confirmation="Update status, priority and owner. The server will reject this save if another operator changed the case since it was opened.">
          <input type="hidden" name="operation_id" value={randomUUID()}/><input type="hidden" name="case_id" value={row.support_case_id}/><input type="hidden" name="expected_updated_at" value={row.updated_at}/>
          <label>Status<select name="status" className="select" defaultValue={row.status}>{supportStates.map(s=><option key={s} value={s}>{human(s)}</option>)}</select></label><label>Priority<select name="priority" className="select" defaultValue={row.priority}>{supportPriorities.map(s=><option key={s} value={s}>{s}</option>)}</select></label>
          <SupportStaffSelector currentId={row.assignee_id} currentName={row.assignee_name}/>
        </WorkflowForm></OperatorDrawer>
        <Suspense fallback={<p role="status">Loading case history…</p>}><SupportHistory id={row.support_case_id} href={`${base}&source=${row.support_case_id}`} time={params.historyTime} event={params.historyEvent}/></Suspense>
        <details className="workflow-technical"><summary>Technical identifiers</summary><code>Case: {row.support_case_id}</code>{row.member_id&&<code>Member: {row.member_id}</code>}{row.source_id&&<code>Source: {row.source_id}</code>}</details>
        <p className="operator-note">Updates are recorded by the existing audit workflow. Assignment does not prove the member has received a response.</p>
      </OperatorPanel>}
    </div>
  </OperatorPage>;
}
