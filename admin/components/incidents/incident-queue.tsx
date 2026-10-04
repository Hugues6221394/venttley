import Link from 'next/link';
import {OperatorPanel,OperatorTable} from '@/components/ui/operator-workspace';
import {SnapshotFreshness} from '@/components/ui/operator-controls';
import {incidentQueue} from '@/lib/incidents';
import {incidentFilters,incidentHref,incidentSeverities,incidentTime} from '@/lib/incident-model';
export async function IncidentQueuePanel({params}:{params:Record<string,string|string[]|undefined>}) {
 const q=new URLSearchParams();for(const [k,v] of Object.entries(params))if(typeof v==='string')q.set(k,v);
 const filters=incidentFilters(q);
 if(!filters)return <p role="alert">Invalid incident filters. <Link href="/incidents">Reset filters</Link></p>;
 const data=await incidentQueue(filters);
 if(!data)return <p role="alert">Incident data is unavailable. Counts are unknown; refresh to retry.</p>;
 if(!data.enabled)return <p role="status">Incident coordination is disabled. <Link href="/incidents?view=signals">Open signal directory</Link></p>;
 const rows=data.rows.slice(0,30),next=data.rows.length>30?rows.at(-1):undefined;
 return <><SnapshotFreshness at={data.measured_at} state="current"/>
  <div className="incident-metrics">{[['Active incidents',data.active,'Declared through monitoring'],['Response overdue',data.overdue,'Active incidents past their response deadline'],['Awaiting review',data.review,'Resolved incidents awaiting review']].map(([label,value,hint])=><section key={label} className="operator-metric" aria-label={String(label)}><h3>{label}</h3><strong>{Number(value)>1000?'1,000+':Number(value).toLocaleString('en-US')}</strong><p>{hint}</p></section>)}</div>
  <OperatorPanel title="Response queue" hint="Newest declared first. Metrics cover all authorized incidents, not just this page.">
   <form action="/incidents" className="operator-filterbar"><label>View<select name="filter" defaultValue={filters.filter} className="select">{['active','mine','all','review'].map(v=><option key={v} value={v}>{v==='review'?'Awaiting review':v}</option>)}</select></label><label>Severity<select name="severity" defaultValue={filters.severity} className="select"><option value="all">All severities</option>{incidentSeverities.map(v=><option key={v} value={v}>{v.toUpperCase()}</option>)}</select></label><button className="btn-secondary">Apply filters</button></form>
   {rows.length===0?<p className="operator-note">No incidents match these filters.</p>:<OperatorTable caption="Incident response queue" headings={['Incident','Severity / phase','Commander','Response deadline','Response']}>
    {rows.map(i=><tr key={i.incident_id}><td><strong>{i.title}</strong><small className="block">INC-{i.number} · {i.services.join(', ')}</small></td><td>{i.severity.toUpperCase()} · {i.status}</td><td>{i.commander_name??'Former staff member'}</td><td className={!['resolved','reviewed'].includes(i.status)&&Date.parse(i.response_due_at)<Date.parse(data.measured_at)?'text-danger':''}>{!['resolved','reviewed'].includes(i.status)&&Date.parse(i.response_due_at)<Date.parse(data.measured_at)?'Overdue · ':''}{incidentTime(i.response_due_at)}</td><td><Link href={`/incidents/records/${i.incident_id}`} prefetch={false} aria-label={`Open response INC-${i.number}`}>Open response →</Link></td></tr>)}
   </OperatorTable>}{next&&<Link href={incidentHref(filters,next)} prefetch={false} className="btn-secondary">Older incidents</Link>}
  </OperatorPanel></>;
}
