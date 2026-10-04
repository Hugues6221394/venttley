import { readAnalyticsPanel } from '@/lib/analytics';
import { analyticsDays, analyticsSampleLimit, retentionBand, sampleSeries, sampleResolution, type AnalyticsRange, type RetentionRow } from '@/lib/analytics-model';
import { OperatorPanel, OperatorTable, PanelUnavailable } from './ui/operator-workspace';
import { StatCard } from './ui/stat-card';

const retry=(range:AnalyticsRange)=>`/analytics?range=${range}`;
export function AnalyticsBars({rows,label,tone='accent'}:{rows:{day:string;count:number}[];label:string;tone?:'accent'|'ok'|'info'|'warn'}) {
  const peak=Math.max(0,...rows.map(r=>r.count));
  return <>
    <div className={`analytics-bars analytics-bars-${tone}`} aria-hidden="true">{rows.map(r=><div key={r.day}><span style={{height:`${peak?r.count/peak*100:0}%`}}/></div>)}</div>
    <p className="operator-note">{rows[0]?.day} to {rows.at(-1)?.day} · Peak {peak.toLocaleString('en-US')} per day</p>
    <details className="operator-daily-values"><summary>View {label.toLowerCase()} values</summary>
      <OperatorTable caption={label} headings={['Date','Count']}>{rows.map(r=><tr key={r.day}><th scope="row">{r.day}</th><td>{r.count.toLocaleString('en-US')}</td></tr>)}</OperatorTable>
    </details>
  </>;
}
export async function AnalyticsEngagement({range}:{range:AnalyticsRange}) {
  const result=await readAnalyticsPanel('engagement',range),d=result.data;
  return <OperatorPanel title="Member engagement" hint="Existing activity rollup · rolling windows, independent of the chart filter.">
    {!d?<PanelUnavailable label="Member engagement" retryHref={retry(range)}/>:<div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">
      <StatCard label="Registered accounts" value={d.total_users} sub="Not verified humans or active members"/>
      <StatCard label="DAU · today" value={d.active_1d} sub="Recorded activity in the rollup"/>
      <StatCard label="WAU · last 7 days" value={d.active_7d}/>
      <StatCard label="MAU · last 30 days" value={d.active_30d}/>
      <StatCard label="DAU ÷ MAU" value={d.active_30d?`${Math.round(d.active_1d/d.active_30d*100)}%`:'Not applicable'} sub="No percentage when MAU is zero"/>
      <StatCard label="New accounts · 7 days" value={d.new_7d}/>
      <StatCard label="New accounts · 30 days" value={d.new_30d}/>
    </div>}
    <p className="operator-note">The rollup is scheduled hourly, but this API does not report its last successful refresh. Freshness is unknown; these are not live counters.</p>
  </OperatorPanel>;
}
export async function AnalyticsDaily({range}:{range:AnalyticsRange}) {
  const {data}=await readAnalyticsPanel('daily',range);
  return <OperatorPanel title="Daily activity and signups" hint={`${analyticsDays(range)} database calendar days; current day is partial.`}>
    {!data?<PanelUnavailable label="Daily activity" retryHref={retry(range)}/>:<div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <section aria-label="Active accounts per day"><h3 className="h-section">Active accounts</h3><AnalyticsBars label="Daily active accounts" rows={data.map(r=>({day:r.day,count:r.active_users}))}/><p className="operator-note">Daily active counts must not be summed into unique people.</p></section>
      <section aria-label="New accounts per day"><h3 className="h-section">New accounts</h3><AnalyticsBars label="Daily new accounts" rows={data.map(r=>({day:r.day,count:r.new_users}))} tone="ok"/></section>
    </div>}
  </OperatorPanel>;
}
export function RetentionTable({rows}:{rows:RetentionRow[]}) {
  if(!rows.length)return <p className="operator-note">No cohort observations returned. Missing observations are not zero retention.</p>;
  const cohorts=new Map<string,{size:number;cells:Map<number,number>}>();
  for(const r of rows){if(!cohorts.has(r.cohort_week))cohorts.set(r.cohort_week,{size:r.cohort_size,cells:new Map()});cohorts.get(r.cohort_week)!.cells.set(r.week_offset,r.retained);}
  return <OperatorTable caption="New-account weekly retention" headings={['Cohort week','Size','Week 0','Week 1','Week 2','Week 3','Week 4','Week 5']}>
    {[...cohorts].sort(([a],[b])=>b.localeCompare(a)).map(([week,d])=><tr key={week}><th scope="row">{week}</th><td>{d.size.toLocaleString('en-US')}</td>{Array.from({length:6},(_,offset)=>{
      const retained=d.cells.get(offset);
      return <td key={offset}>{retained===undefined?<span aria-label="No observation">—</span>:<span className="analytics-retention-cell" data-band={retentionBand(retained,d.size)}>{Math.round(retained/d.size*100)}%<span className="sr-only">; {retained} of {d.size} accounts</span></span>}</td>;
    })}</tr>)}
  </OperatorTable>;
}
export async function AnalyticsRetention({range}:{range:AnalyticsRange}) {
  const {data}=await readAnalyticsPanel('retention',range);
  return <OperatorPanel title="New-account retention" hint="Six signup cohorts · share observed active in each following week.">
    {data?<RetentionTable rows={data}/>:<PanelUnavailable label="Retention" retryHref={retry(range)}/>}
    <p className="operator-note">Weeks in progress are partial. A dash means no observation returned, not 0%. Color supplements the printed percentage.</p>
  </OperatorPanel>;
}
export async function AnalyticsSamples({range}:{range:AnalyticsRange}) {
  const result=await readAnalyticsPanel('samples',range),d=result.data;
  const resolution=d?.reports?sampleResolution(d.reports):null;
  const names={posts:'Vent records',comments:'Comment records',reactions:'Reaction records',reports:'Report records'};
  return <OperatorPanel title="Recent record samples" hint={`Up to ${analyticsSampleLimit} latest records per source in ${analyticsDays(range)} UTC calendar days. Not platform totals or representative rates.`}>
    {!d||!result.receivedAt?<PanelUnavailable label="Recent record samples" retryHref={retry(range)}/>:<>
      <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">{(Object.keys(names) as (keyof typeof names)[]).map(kind=>{
        const rows=d[kind];return rows?<StatCard key={kind} label={`${names[kind]} inspected`} value={rows.length} sub="Bounded sample, not a global count"/>:<PanelUnavailable key={kind} label={names[kind]} retryHref={retry(range)}/>;
      })}</div>
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 mt-5">{(['posts','comments','reactions'] as const).map((kind,i)=>d[kind]&&<section key={kind} aria-label={`${names[kind]} sample`}><h3 className="h-section">{names[kind]} · sample only</h3><AnalyticsBars rows={sampleSeries(d[kind]!,analyticsDays(range),result.receivedAt!)} label={`${names[kind]} sample`} tone={(['accent','info','warn'] as const)[i]}/></section>)}</div>
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-5">
        {d.posts&&<section aria-label="Sample categories"><h3 className="h-section">Categories in the Vent sample</h3><OperatorTable caption="Sample Vent categories" headings={['Category','Inspected records']}>{[...d.posts.reduce((counts,r)=>{const key=r.category_name||'Unspecified';counts.set(key,(counts.get(key)??0)+1);return counts;},new Map<string,number>())].sort((a,b)=>b[1]-a[1]).slice(0,8).map(([category,n])=><tr key={category}><th scope="row">{category}</th><td>{n}</td></tr>)}</OperatorTable></section>}
        {d.reports&&<section aria-label="Sample moderation outcomes"><h3 className="h-section">Moderation outcomes in the sample</h3><p className="operator-note">{d.reports.filter(r=>r.is_resolved).length} resolved · {d.reports.filter(r=>!r.is_resolved).length} unresolved among {d.reports.length} inspected reports.</p><p className="operator-note">Average resolution in this sample: {resolution?.minutes===null?'not observed':`${resolution?.minutes} minutes`} · {resolution?.observations} resolved records with timestamps.</p><p className="operator-note">Not the current queue size or an SLA measurement. Use the permission-scoped operational queues for action.</p></section>}
      </div>
      <p className="operator-note">Sample cutoff: <time dateTime={result.receivedAt}>{result.receivedAt}</time>. Removed Vents are excluded; other record types follow their existing table semantics. Response limits may shorten samples. No prior-period percentage is inferred from samples.</p>
    </>}
  </OperatorPanel>;
}
