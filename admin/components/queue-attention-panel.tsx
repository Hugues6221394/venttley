'use client';

import Link from 'next/link';
import { useStaffAttention } from './staff-attention';
import { queueDestinations, staleTimestamp, type AttentionQueue } from '@/lib/inbox-model';
import { OperatorPanel, OperatorTable } from './ui/operator-workspace';

// One provider/request per workspace. Page KPI, Overview and nav badge consume
// the very same response; this component never starts another polling loop.
export function QueueAttentionPanel({ queue }: { queue?: AttentionQueue }) {
  const a = useStaffAttention();
  if (!a.queuesAvailable) return null;
  const rows = a.data?.enabled ? a.data.queues.filter(row => !queue || row.key === queue) : [];
  // A refreshed response with no key means this role has no such source access.
  if (queue && a.data?.enabled && rows.length === 0) return null;
  return <div className="operator-page" data-attention-panel={queue ?? 'all'}>
    <OperatorPanel title={queue ? queueDestinations[queue].label : 'Needs attention'}
      hint="Team workload · not personal unread notifications."
      actions={<button className="btn-secondary" type="button" disabled={a.loading} onClick={a.refresh}>{a.loading ? 'Checking counts…' : 'Refresh counts'}</button>}>
      {a.error ? <p role="status">Counts unavailable. Check your connection or session, then retry.</p> :
        !a.data ? <p role="status">Checking authorized queues…</p> :
        !a.data.enabled ? <p role="status">Attention pilot is not enabled for this account. Use the source queues.</p> :
        !rows.length ? <p>Your role has no triage queues in this summary.</p> :
        <OperatorTable caption="Shared actionable queue counts" headings={['Queue', 'Open', 'Freshness']}>
          {rows.map(row => {
            const definition = queueDestinations[row.key];
            const unknown = a.stale || row.stale || staleTimestamp(row.measured_at);
            return <tr key={row.key}><th scope="row"><Link href={definition.href} prefetch={false}>{definition.label} <span aria-hidden="true">→</span></Link>
              <p className="operator-note">{definition.definition}</p></th>
              <td className="tabular" data-queue-value={row.key}>{unknown ? '—' : row.key==='jobs'&&row.count>99?'99+':row.count.toLocaleString('en-US')}</td>
              <td>{unknown ? <span>Awaiting reconciliation or stale</span> : <span>Measured</span>}<br/>
                <time dateTime={row.measured_at}>{new Date(row.measured_at).toISOString().replace('T',' ').slice(0,19)} UTC</time></td></tr>;
          })}
        </OperatorTable>}
      <p className="operator-note">Checks every 30 seconds while visible; backs off on failures. Counts are reconciled by the minute worker, not instantly. Source lists may be newer or limited. Reading a notification never resolves work.</p>
    </OperatorPanel>
  </div>;
}
