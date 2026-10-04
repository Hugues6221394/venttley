'use client';
import { useEffect, useId, useRef, useState, useTransition, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { RefreshCw, X } from 'lucide-react';
import { containDialogTab } from '@/lib/dialog-focus';
import { snapshotStale } from '@/lib/overview-model';

export function RefreshOverview() {
  const router=useRouter(); const [pending,start]=useTransition();
  return <><button className="btn-primary" disabled={pending} onClick={()=>start(()=>router.refresh())}><RefreshCw size={15}/>{pending?'Refreshing…':'Refresh overview'}</button><span className="sr-only" role="status">{pending?'Refreshing overview snapshots':''}</span></>;
}
export function SnapshotFreshness({ at, state }: { at:string|null; state:string }) {
  const [now,setNow]=useState<number|null>(null);
  useEffect(()=>{setNow(Date.now());const timer=setInterval(()=>setNow(Date.now()),30000);return()=>clearInterval(timer);},[]);
  const stale=state==='stale'||(now!==null&&snapshotStale(at,now));
  return <p className={`operator-freshness ${stale?'is-stale':''}`} role="status">{!at?'Snapshot unavailable':<>{stale?'Stale snapshot':'Snapshot'} · <time dateTime={at}>{new Date(at).toISOString().replace('T',' ').slice(0,19)} UTC</time>{stale?' · refresh or check the worker':''}</>}</p>;
}
export function OperatorDrawer({ title, trigger, children }: { title:string; trigger:string; children:ReactNode }) {
  const [open,setOpen]=useState(false); const dialog=useRef<HTMLDialogElement>(null),button=useRef<HTMLButtonElement>(null); const id=useId();
  useEffect(()=>{if(open)dialog.current?.showModal();},[open]);
  // End native modal inertness before returning focus to the trigger.
  const close=()=>{
    // A request can commit even if its form disappears. Keep its receipt and
    // inputs mounted until the response settles; never imply closing cancels it.
    if(dialog.current?.querySelector('form[aria-busy="true"]'))return;
    dialog.current?.close();setOpen(false);button.current?.focus();
  };
  return <><button ref={button} className="btn-secondary" aria-haspopup="dialog" aria-expanded={open} onClick={()=>setOpen(true)}>{trigger}</button>
    {open&&<dialog ref={dialog} className="operator-detail-drawer" aria-labelledby={id} onCancel={e=>{e.preventDefault();close();}} onKeyDown={containDialogTab}>
      <header><h2 id={id}>{title}</h2><button className="icon-btn" autoFocus aria-label={`Close ${title}`} onClick={close}><X size={20}/></button></header><div className="operator-drawer-content">{children}</div></dialog>}</>;
}
