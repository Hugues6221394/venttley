import Link from 'next/link';
import { readOverviewPanel } from '@/lib/overview';
import { percentChange, regionPercent, dailyReports } from '@/lib/overview-model';
import { OperatorPanel, OperatorMetric, OperatorTable, PanelUnavailable } from './ui/operator-workspace';
import { SnapshotFreshness } from './ui/operator-controls';
import { ReportVolume } from './overview-report-volume';
import { QueueAttentionPanel } from './queue-attention-panel';
import { Users, PenLine, UserPlus, MessageSquareText } from 'lucide-react';

const regionNames=new Intl.DisplayNames(['en'],{type:'region'});
const regionName=(code:string)=>{if(!/^[A-Z]{2}$/.test(code))return code;try{return regionNames.of(code)??code;}catch{return code;}};
const comparison=(current:number,previous:number)=>{const change=percentChange(current,previous);return change===null?'No percentage comparison: previous period was zero':`${change>0?'+':''}${change}% vs previous 24 hours`;};
export async function ActivityPanel() {
  const s=await readOverviewPanel('activity');const d=s.data;
  return <section className="operator-activity" aria-label="Community activity">
    <div className="operator-period"><span>Rolling 24 hours</span><SnapshotFreshness at={s.measured_at} state={s.state}/></div>
    {!d?<PanelUnavailable label="Community activity"/>:<div className="operator-metrics">
      <OperatorMetric label="Registered members" value={d.total_members} icon={<Users size={15}/>} description="Current registered accounts, not active users"/>
      <OperatorMetric label="Unique writers · 24h" value={d.unique_writers} icon={<PenLine size={15}/>} description="Post or comment authors, counted once"/>
      <OperatorMetric label="New members · 24h" value={d.new_members} icon={<UserPlus size={15}/>} delta={percentChange(d.new_members,d.previous_members)} description="Accounts created in this window" comparison={comparison(d.new_members,d.previous_members)}/>
      <OperatorMetric label="Vents created · 24h" value={d.vents} icon={<MessageSquareText size={15}/>} delta={percentChange(d.vents,d.previous_vents)} description={`${d.comments.toLocaleString('en-US')} non-removed comments · removed Vents excluded`} comparison={comparison(d.vents,d.previous_vents)}/>
    </div>}
  </section>;
}
const queueInfo={moderation:{label:'Moderation reports',href:'/moderation?tab=pending'},appeals:{label:'Appeals',href:'/appeals?tab=open'},support:{label:'Support cases',href:'/support/cases?queue=open'}};
export async function AttentionPanel() {
  if (process.env.ADMIN_ATTENTION_UI === 'true') return <QueueAttentionPanel/>;
  const s=await readOverviewPanel('queues');
  return <OperatorPanel title="Needs attention" className="operator-queue-panel" hint="Open work in your permitted queues."><SnapshotFreshness at={s.measured_at} state={s.state}/>
    {!s.data?<PanelUnavailable label="Queue snapshots"/>:Object.keys(s.data).length===0?<p className="operator-note">Your role has no triage queues in this overview. Use your permitted workspace links.</p>:<OperatorTable caption="Actionable queue snapshots" headings={['Queue','Open','Next step']}>
      {Object.entries(s.data).map(([key,count])=>{const q=queueInfo[key as keyof typeof queueInfo];return <tr key={key}><th scope="row">{q.label}</th><td><span className={`queue-count ${count===0?'is-zero':count?'is-open':''}`}>{count?.toLocaleString('en-US')}</span></td><td className="text-right"><Link href={q.href} prefetch={false} className="queue-open" aria-label={`Open ${q.label.toLowerCase()} queue`}>Open queue <span aria-hidden="true">→</span></Link></td></tr>;})}
    </OperatorTable>}<p className="operator-note">Separate queues; counts must not be summed into unique incidents. Queue contents may have changed since this snapshot.</p>
  </OperatorPanel>;
}
export async function ReportsPanel() {
  const s=await readOverviewPanel('reports');
  return <OperatorPanel title="Report volume · 30 UTC days" className="operator-context-panel" hint="Daily report submissions, not open workload."><SnapshotFreshness at={s.measured_at} state={s.state}/>
    {!s.data||!s.measured_at?<PanelUnavailable label="Report volume"/>:<ReportVolume rows={dailyReports(s.data,s.measured_at)}/>}
  </OperatorPanel>;
}
export async function RegionsPanel() {
  const s=await readOverviewPanel('regions');
  return <OperatorPanel title="Member regions" className="operator-context-panel" hint="Top regions · share of all registered accounts."><SnapshotFreshness at={s.measured_at} state={s.state}/>
    {!s.data?<PanelUnavailable label="Member regions"/>:s.data.rows.length===0?<p className="operator-note">No regions meet the ten-account display threshold. Unknown locations are withheld.</p>:<ul className="operator-regions">{s.data.rows.map(row=>{const pct=regionPercent(row.count,s.data!.total_members);return <li key={row.country}><div><span><span className="operator-region-code" aria-hidden="true">{row.country.slice(0,3).toUpperCase()}</span>{regionName(row.country)}</span><span>{row.count.toLocaleString('en-US')} · {pct}%</span></div><div className="operator-region-bar" aria-hidden="true"><span style={{width:`${pct}%`}}/></div></li>;})}</ul>}
    <p className="operator-note">Small groups and unknown locations withheld. Up to eight regions; percentages need not total 100%.</p>
  </OperatorPanel>;
}
