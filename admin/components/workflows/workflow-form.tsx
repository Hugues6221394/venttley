'use client';

import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useStaffAttention } from '@/components/staff-attention';
import { workflowFailure, type WorkflowAction, type WorkflowResult } from '@/lib/workflow-model';

// Inputs stay in the mounted form, not localStorage, a URL, or an error payload.
// Mutations are never optimistically reported as complete or automatically retried.
export function WorkflowForm({action,label,confirmation,children,onRefresh,disabled=false,blockUncertainRetry=false}: {
  action:WorkflowAction;label:string;confirmation:string;children:ReactNode;onRefresh?:()=>void;disabled?:boolean;blockUncertainRetry?:boolean;
}) {
  const id=useId(),form=useRef<HTMLFormElement>(null),busy=useRef(false);
  const [pending,setPending]=useState(false),[review,setReview]=useState(false),[result,setResult]=useState<WorkflowResult|null>(null);
  const [ready,setReady]=useState(false);
  useEffect(()=>setReady(true),[]);
  const approved=useRef(false),operation=useRef<string|null>(null);
  const router=useRouter(),attention=useStaffAttention();
  const uncertainLocked=blockUncertainRetry&&result?.status==='unknown';
  useEffect(()=>{
    const input=result?.field?form.current?.elements.namedItem(result.field):null;
    if(!(input instanceof HTMLElement))return;
    const description=input.getAttribute('aria-describedby');
    input.setAttribute('aria-invalid','true');input.setAttribute('aria-describedby',[description,id].filter(Boolean).join(' '));input.focus();
    return()=>{input.removeAttribute('aria-invalid');if(description)input.setAttribute('aria-describedby',description);else input.removeAttribute('aria-describedby');};
  },[result,id]);
  async function submit(event:React.FormEvent<HTMLFormElement>) {
    event.preventDefault();if(!ready||disabled||busy.current||result?.status==='success'||uncertainLocked)return;
    if(!approved.current){setReview(true);return;}
    approved.current=false;setReview(false);
    const fd=new FormData(event.currentTarget);
    if(fd.has('operation_id')){operation.current??=String(fd.get('operation_id'));fd.set('operation_id',operation.current);}
    busy.current=true;setPending(true);setResult(null);
    try {
      const response=await action(fd);setResult(response);
      if(response.status==='success')attention.refresh();
    }catch{setResult(workflowFailure('failed'));}
    finally{busy.current=false;setPending(false);}
  }
  return <form ref={form} method="post" onSubmit={submit} className="workflow-form" aria-label={label} aria-busy={pending}
    onChange={()=>{if(!busy.current){setReview(false);approved.current=false;}}}>
    <fieldset disabled={!ready||disabled||pending||result?.status==='success'||uncertainLocked}>{children}</fieldset>
    {pending&&<p role="status">Saving. Keep this drawer open until the result is confirmed.</p>}
    {review&&<section className="workflow-confirm" aria-label="Confirm action"><h3>Review before saving</h3><p>{confirmation}</p>
      <button type="button" className="btn-primary" disabled={disabled} onClick={()=>{approved.current=true;form.current?.requestSubmit();}}>Confirm {label.toLowerCase()}</button>
      <button type="button" className="btn-secondary" onClick={()=>setReview(false)}>Keep editing</button></section>}
    {!review&&result?.status!=='success'&&<button className="btn-primary" type="submit" disabled={!ready||disabled||pending||uncertainLocked}>{pending?'Saving…':label}</button>}
    {result&&<div id={id} role={result.status==='success'?'status':'alert'} className={`workflow-result is-${result.status}`}>
      <p>{result.message}</p>
      {uncertainLocked&&<p>Resubmission is disabled until you inspect the current record and audit trail. Refreshing is not proof that the earlier operation failed.</p>}
      {result.status==='success'&&result.destination&&/^\/incidents\/records\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(result.destination)&&<Link className="btn-primary" href={result.destination}>Open saved incident</Link>}
      {result.field&&<p>Field: {result.field.replaceAll('_',' ')}</p>}
      <button type="button" className="btn-secondary" onClick={()=>{attention.refresh();if(onRefresh)onRefresh();else router.refresh();}}>Refresh current record</button>
      {result.message.includes('MFA')&&<a className="btn-secondary" href="/mfa" target="_blank" rel="noopener noreferrer">Complete MFA</a>}
    </div>}
    <p className="operator-note">Inputs remain only in this open page. Closing or navigating away discards unsaved edits.</p>
    <noscript>JavaScript is required for confirmed actions. No form data has been submitted.</noscript>
  </form>;
}
