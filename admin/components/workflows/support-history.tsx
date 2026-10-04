import Link from 'next/link';
import {supportHistory} from '@/lib/workflows';

export async function SupportHistory({id,href,time,event}:{id:string;href:string;time?:string;event?:string}) {
  const history=await supportHistory(id,time,event);
  const next=history.next;
  return <section className="workflow-context" aria-label="Support case history">
    <h3>Case history</h3>
    {history.error?<p role="status">History is unavailable. Reload to retry; the current case remains usable.</p>:<>
      {!history.rows.length?<p>No recorded events in this view.</p>:<ol className="workflow-history">{history.rows.map(row=><li key={row.event_id}>
        <strong>{row.event_kind.replaceAll('_',' ')}</strong><p>{row.actor_name??'Former staff member'} · <time dateTime={row.created_at}>{new Date(row.created_at).toISOString().slice(0,19).replace('T',' ')} UTC</time></p>
        {row.to_status&&<p>{row.from_status ? `${row.from_status.replaceAll('_',' ')} → ` : ''}{row.to_status.replaceAll('_',' ')}</p>}
        {row.priority&&<p>Priority: {row.priority}{row.assigned===null?'':row.assigned?' · Assigned':' · Unassigned'}</p>}
      </li>)}</ol>}
      <nav className="operator-actions" aria-label="Case history pages">{time&&<Link prefetch={false} href={href}>Latest events</Link>}{next&&<Link prefetch={false} href={`${href}&historyTime=${encodeURIComponent(next.created_at)}&historyEvent=${next.event_id}`}>Older events</Link>}</nav>
    </>}
    <p className="operator-note">Recorded workflow changes, not a transcript of member communications.</p>
  </section>;
}
