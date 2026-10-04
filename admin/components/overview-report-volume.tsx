'use client';
import { useState } from 'react';
import type { ReportDay } from '@/lib/overview-model';
import { OperatorFilterBar, OperatorTable } from './ui/operator-workspace';

export function ReportVolume({rows}:{rows:ReportDay[]}) {
  const [days,setDays]=useState(30); const visible=rows.slice(-days);const max=Math.max(1,...visible.map(r=>r.count));
  return <><OperatorFilterBar label="Report chart window"><label htmlFor="overview-report-days">Display window</label><select id="overview-report-days" className="select" value={days} onChange={e=>setDays(Number(e.target.value))}><option value={30}>30 UTC days</option><option value={7}>7 UTC days</option></select></OperatorFilterBar>
    <div className="operator-report-bars" aria-hidden="true">{visible.map(row=><div key={row.day} title={`${row.day}: ${row.count}`}><span style={{height:`${row.count/max*100}%`}}/></div>)}</div>
    <p className="operator-note" role="status">{visible.reduce((sum,row)=>sum+row.count,0).toLocaleString('en-US')} reports · {visible[0]?.day} to {visible.at(-1)?.day} (UTC; current day partial)</p>
    <details className="operator-daily-values"><summary>View daily values</summary><OperatorTable caption="Daily report submissions" headings={['UTC date','Reports']}>{visible.map(row=><tr key={row.day}><th scope="row">{row.day}</th><td>{row.count.toLocaleString('en-US')}</td></tr>)}</OperatorTable></details>
  </>;
}
