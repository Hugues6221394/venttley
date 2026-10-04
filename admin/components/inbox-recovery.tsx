'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { Activity, Clock3, TriangleAlert, Power, RefreshCw, X } from 'lucide-react';
import { OperatorPage, OperatorPanel, OperatorTable } from './ui/operator-workspace';
import { WorkflowForm } from './workflows/workflow-form';
import { retryStaffNotification } from '@/lib/inbox-recovery-actions';
import { inboxCopy, pollDelay, staleTimestamp } from '@/lib/inbox-model';
import { parseRecoverySnapshot, recoveryReasons, type FailedNotice, type RecoveryCursor, type RecoverySnapshot } from '@/lib/inbox-recovery-model';
import { containDialogTab } from '@/lib/dialog-focus';

const date=(at:string|null)=>at?new Date(at).toISOString().replace('T',' ').slice(0,19)+' UTC':'Not recorded';
// Ported from the approved 12ui failure queue + recovery state. The shared
// shell stays authoritative; invented bulk/channel/recipient controls are omitted.
export default function InboxRecovery() {
  const [snapshot,setSnapshot]=useState<RecoverySnapshot|null>(null),[error,setError]=useState<string|null>(null);
  const [loading,setLoading]=useState(true),[cursor,setCursor]=useState<RecoveryCursor|undefined>();
  const [selected,setSelected]=useState<{notice:FailedNotice;operation:string}|null>(null);
  const [now,setNow]=useState(Date.now());
  const refresh=useRef<()=>void>(()=>{}),trigger=useRef<HTMLButtonElement|null>(null),dialog=useRef<HTMLDialogElement>(null);
  useEffect(()=>{
    let stopped=false,pending=false,failures=0,lastStart=0,again=false;
    let timer:ReturnType<typeof setTimeout>,controller:AbortController|null=null;
    const schedule=()=>{clearTimeout(timer);if(!stopped&&!document.hidden)timer=setTimeout(run,pollDelay(failures));};
    async function run(){
      if(stopped||document.hidden)return;
      if(pending){again=true;return;}
      pending=true;lastStart=Date.now();setLoading(true);controller=new AbortController();
      const timeout=setTimeout(()=>controller?.abort(),12_000);
      try {
        const query=new URLSearchParams(cursor?{afterAt:cursor.at,afterId:cursor.id}:{});
        const response=await fetch(`/inbox/operations/data?${query}`,{signal:controller.signal,credentials:'same-origin',cache:'no-store',redirect:'error'});
        if(stopped)return;
        if(response.status===403||response.status===401||response.status===409){
          setSelected(null);throw Error('access');
        }
        if(!response.ok)throw Error('unavailable');
        const next=parseRecoverySnapshot(await response.json());
        if(!next)throw Error('unavailable');
        if(stopped)return;
        setSnapshot(next);setError(null);failures=next.health&&next.items?0:failures+1;
      }catch(cause){if(!stopped){setSnapshot(null);setError(cause instanceof Error&&cause.message==='access'?'Recovery access is unavailable or the interface was disabled.':'Recovery data could not be refreshed. Counts are unknown.');failures++;}}
      finally{clearTimeout(timeout);pending=false;if(!stopped){setNow(Date.now());setLoading(false);if(again){again=false;timer=setTimeout(run,500);}else schedule();}}
    }
    const focus=()=>{if(!document.hidden&&Date.now()-lastStart>1000){clearTimeout(timer);void run();}};
    const visibility=()=>{clearTimeout(timer);if(document.hidden){again=false;controller?.abort();}else focus();};
    refresh.current=()=>{clearTimeout(timer);void run();};
    window.addEventListener('focus',focus);window.addEventListener('online',focus);document.addEventListener('visibilitychange',visibility);
    const tick=setInterval(()=>{if(!document.hidden)setNow(Date.now());},15_000);
    setSnapshot(null);void run();
    return()=>{stopped=true;clearTimeout(timer);clearInterval(tick);controller?.abort();refresh.current=()=>{};window.removeEventListener('focus',focus);window.removeEventListener('online',focus);document.removeEventListener('visibilitychange',visibility);};
  },[cursor]);
  useEffect(()=>{if(selected)dialog.current?.showModal();},[selected]);
  const close=()=>{
    if(dialog.current?.querySelector('[aria-busy="true"]'))return;
    dialog.current?.close();setSelected(null);
    if(trigger.current?.isConnected)trigger.current.focus();else document.getElementById('recovery-refresh')?.focus();
  };
  const health=snapshot?.health,stale=!!snapshot&&staleTimestamp(snapshot.at,now);
  const worker=health?(health.enabled?(health.worker_stale||staleTimestamp(health.worker_at,now)?'Stale':'Recent'):'Off'):'Unknown';
  const mayRetry=!!health?.enabled&&!stale&&!error;
  const history=snapshot?.observability?.hours;
  const observedMax=history?.reduce<number|null>((max,h)=>h.max_delivery_lag_seconds===null?max:Math.max(max??0,h.max_delivery_lag_seconds),null);
  return <OperatorPage title="Notification operations" subtitle="Inspect delivery failures and recover one event at a time. In-app staff notices only."
    actions={<><Link href="/inbox" prefetch={false} className="btn-secondary">Staff inbox</Link><button id="recovery-refresh" className="btn-secondary" disabled={loading} onClick={()=>refresh.current()}><RefreshCw size={15}/>{loading?'Refreshing…':'Refresh recovery'}</button></>}>
    <div className="recovery-metrics">
      {[{label:'Worker freshness',value:worker,note:health?date(health.worker_at):'Health source unavailable',Icon:Activity},
        {label:'Pending events',value:health?.pending.toLocaleString('en-US')??'—',note:'Global worker backlog; not unread notices',Icon:Clock3},
        {label:'Failed events',value:health?.failed.toLocaleString('en-US')??'—',note:'Global failures; visible rows require source access',Icon:TriangleAlert},
        {label:'Processing',value:health?(health.enabled?'Enabled':'Off'):'Unknown',note:'This screen cannot change the rollout',Icon:Power}].map(({label,value,note,Icon})=>
        <section key={label} className="recovery-metric" aria-label={label}><span className="recovery-metric-icon"><Icon size={21} aria-hidden="true"/></span><div><h2>{label}</h2><strong>{value}</strong><p>{note}</p></div></section>)}
    </div>
    <p className="operator-freshness" role="status">{loading?'Refreshing snapshot…':snapshot?`${stale?'Stale snapshot':'Snapshot'} · ${date(snapshot.at)}`:'Snapshot unavailable'} · Refreshes every 30 seconds while visible; errors back off.</p>
    <p className="operator-note" data-notification-history>{history?.length?`Recorded batches in ${history.length} UTC hour buckets within the last 24 hours: ${history.reduce((n,h)=>n+h.delivered_events,0).toLocaleString('en-US')} delivered event outcomes; ${history.reduce((n,h)=>n+h.failed_attempts,0).toLocaleString('en-US')} failed attempts. Maximum observed queue-to-worker lag: ${observedMax===null?'not recorded':`${Math.ceil(observedMax??0)} seconds`}. Missing hours are unknown. This is not recipient-open latency or a percentile.`:'Delivery history is unavailable or has no recorded batches; no zero or healthy state is inferred.'}</p>
    {error&&<p role="alert" className="operator-unavailable">{error}</p>}
    {health&&!health.enabled&&<p className="recovery-notice">Processing is off. You can inspect failures, but retries are disabled. No delivery is implied.</p>}
    <OperatorPanel title="Failure queue" hint="Oldest failures first. Only event metadata is shown; messages, recipients and evidence are excluded.">
      {snapshot?.items===null?<p role="status" className="operator-unavailable">Failure queue unavailable. No empty or healthy state is inferred.</p>:
        !snapshot?<p role="status">{loading?'Loading failure queue…':'Failure queue unavailable.'}</p>:
        snapshot.items.length===0?<p className="operator-note">No accessible failed events on this page. This does not prove delivery to every recipient.</p>:
        <OperatorTable caption="Failed staff notification events" headings={['Event kind','Severity','Attempts','SQLSTATE','Created (UTC)','Action']}>
          {snapshot.items.map(notice=><tr key={notice.event_id}><td>{inboxCopy[notice.kind].title}</td><td><span className={`recovery-severity is-${notice.severity}`}>{notice.severity}</span></td><td>{notice.attempts}</td><td><code>{notice.last_error_code??'Unknown'}</code></td><td><time dateTime={notice.created_at}>{date(notice.created_at)}</time></td><td><button className="btn-secondary" onClick={event=>{trigger.current=event.currentTarget;setSelected({notice,operation:crypto.randomUUID()});}}>Review retry</button></td></tr>)}
        </OperatorTable>}
      <nav aria-label="Failure queue pagination" className="recovery-pagination"><span>Up to 30 events per page</span><button className="btn-secondary" disabled={!cursor||loading} onClick={()=>setCursor(undefined)}>First page</button><button className="btn-secondary" disabled={!snapshot?.next||loading} onClick={()=>{if(snapshot?.next)setCursor(snapshot.next);}}>Next failures</button></nav>
    </OperatorPanel>
    <p className="operator-note">A retry queues the existing event again. It does not guarantee delivery, mark notices unread, or resolve the original support or legal task. The audit records the reason and prior failure class.</p>
    {selected&&<dialog ref={dialog} className="operator-detail-drawer recovery-drawer" aria-labelledby="recovery-title" onCancel={event=>{event.preventDefault();close();}} onKeyDown={containDialogTab}>
      <header><h2 id="recovery-title">Review notification retry</h2><button autoFocus className="icon-btn" aria-label="Close notification retry" onClick={close}><X size={20}/></button></header>
      <div className="operator-drawer-content"><p>Review the failure, select a fixed reason, then confirm. Current super-admin access and MFA are checked again when saving.</p>
        <dl className="recovery-detail"><dt>Event kind</dt><dd>{inboxCopy[selected.notice.kind].title}</dd><dt>Severity</dt><dd>{selected.notice.severity}</dd><dt>Attempts</dt><dd>{selected.notice.attempts}</dd><dt>SQLSTATE</dt><dd>{selected.notice.last_error_code??'Unknown'}</dd><dt>Created</dt><dd>{date(selected.notice.created_at)}</dd></dl>
        <p className="recovery-notice">Queued again is not delivered. Existing read states remain unchanged.</p>
        <WorkflowForm key={selected.operation} label="Queue retry" confirmation="Queue this event again using the selected reason? Delivery happens separately; no existing notice will be marked unread."
          disabled={!mayRetry} onRefresh={()=>refresh.current()} action={async form=>{const result=await retryStaffNotification(form);refresh.current();return result;}}>
          <input type="hidden" name="operation_id" value={selected.operation}/><input type="hidden" name="event_id" value={selected.notice.event_id}/>
          <label>Reason for retry<select name="reason_code" defaultValue="" required><option value="" disabled>Select a reason</option>{Object.entries(recoveryReasons).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label>
          {!mayRetry&&<p role="status">Retry is unavailable until an enabled, current processing snapshot is verified.</p>}
        </WorkflowForm>
      </div>
    </dialog>}
  </OperatorPage>;
}
