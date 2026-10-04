import {notFound} from 'next/navigation';
import Link from 'next/link';
import {incidentDetail,incidentUIEnabled} from '@/lib/incidents';
import {isUuid} from '@/lib/inbox-model';
import {incidentRunbooks,incidentStates,incidentTime} from '@/lib/incident-model';
import {OperatorPage,OperatorPanel} from '@/components/ui/operator-workspace';
import {OperatorDrawer,SnapshotFreshness} from '@/components/ui/operator-controls';
import {IncidentActions,IncidentForm,RefreshIncidents} from '@/components/incidents/incident-controls';
export const dynamic='force-dynamic';
export default async function Page({params,searchParams}:{params:Promise<{id:string}>;searchParams:Promise<{before?:string}>}){
 const {id}=await params,{before}=await searchParams;if(!isUuid(id)||!await incidentUIEnabled())notFound();
 const cursor=before===undefined?undefined:Number(before);if(cursor!==undefined&&(!Number.isSafeInteger(cursor)||cursor<1))notFound();
 const data=await incidentDetail(id,cursor);
 if(!data||!data.enabled)return <OperatorPage title="Incident unavailable" subtitle="The record is unavailable, access changed, or coordination is disabled." actions={<><Link href="/incidents">Back to incidents</Link><RefreshIncidents/></>}><p>No healthy or resolved state can be inferred.</p></OperatorPage>;
 const i=data.incident,events=data.events.slice(0,50),next=data.events.length>50?events.at(-1)?.version:undefined;
 return <OperatorPage title={i.title} subtitle={`INC-${i.number} · ${i.severity.toUpperCase()} · ${i.status}`} actions={<><IncidentActions incident={i}/><RefreshIncidents/><Link href="/incidents">Response queue</Link></>}>
  <SnapshotFreshness at={data.measured_at} state="current"/>
  <section className="incident-facts" aria-label="Response ownership"><div><h2>Commander</h2><p>{i.commander_name??'Former staff member'}</p></div><div><h2>Responders</h2><p>{i.responder_names?.map(s=>s.display_name).join(', ')||`${i.responders.length} assigned`}</p></div><div><h2>Affected services</h2><p>{i.services.join(', ')}</p></div><div><h2>Response deadline</h2><p>{incidentTime(i.response_due_at)}</p></div><div><h2>Resources</h2><Link href={incidentRunbooks[i.runbook]}>Internal runbook</Link>{i.signal&&<Link className="block" href={`/incidents/${i.signal}`}>Linked signal</Link>}</div></section>
  <div className="incident-detail-grid"><div><OperatorPanel title="Lifecycle"><ol className="incident-lifecycle">{incidentStates.map(s=><li key={s} aria-current={s===i.status?'step':undefined}>{s}</li>)}</ol><p className="operator-note">Current phase only. Earlier phases can be reopened; the timeline is the authoritative history.</p></OperatorPanel>
   <OperatorPanel title="Decisions & updates" hint="Append-only internal coordination history. Newest first."><ol className="incident-timeline">{events.map(e=><li key={e.event_id}><header><strong>{e.kind==='note'&&typeof e.detail.kind==='string'?e.detail.kind:e.kind.replaceAll('_',' ')}</strong><time dateTime={e.created_at}>{incidentTime(e.created_at)}</time></header><small>{e.actor_name??'Former staff member'} · version {e.version}</small>{typeof e.detail.to==='string'&&<p>Phase: {String(e.detail.from)} → {e.detail.to}</p>}<p className="whitespace-pre-wrap">{e.note}</p></li>)}</ol>{next&&<Link href={`/incidents/records/${id}?before=${next}`} prefetch={false}>Older updates</Link>}{before&&<Link className="block" href={`/incidents/records/${id}`}>Latest updates</Link>}</OperatorPanel></div>
   <OperatorPanel title="Postmortem actions" hint={`${data.actions.filter(a=>!!a.completed_at).length} / ${data.actions.length} complete`}>
    {data.actions.length===0?<p className="operator-note">No follow-ups recorded.</p>:<ul className="incident-timeline">{data.actions.map(a=><li key={a.action_id}><strong>{a.title}</strong><p>{a.owner_name??'Former staff member'} · {incidentTime(a.due_at)}</p>{a.completed_at?<p>Completed {incidentTime(a.completed_at)}</p>:i.status!=='reviewed'?<OperatorDrawer title="Complete follow-up" trigger="Complete follow-up"><IncidentForm incident={i} command="action_complete" actionId={a.action_id}/></OperatorDrawer>:<p>Open</p>}</li>)}</ul>}
   </OperatorPanel></div>
  <p className="incident-advisory">Internal records only. Restricted evidence, kill switches, rollback execution and external paging remain separate controls.</p>
 </OperatorPage>;
}
