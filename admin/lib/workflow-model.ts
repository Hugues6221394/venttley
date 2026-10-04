import { isUuid } from './inbox-model';

export type WorkflowResult = { status:'success'|'error'|'unknown'; message:string; field?:string; destination?:string };
export type WorkflowAction = (data:FormData)=>Promise<WorkflowResult>;
export type WorkCursor={a:number;b:number;t:string;k:string;i:string};
export function workCursor(raw?:string):WorkCursor|null {
  if(!raw)return null;
  if(raw.length>512)throw Error('invalid_cursor');
  const v=JSON.parse(raw);
  if(!v||!Number.isInteger(v.a)||!Number.isInteger(v.b)||typeof v.t!=='string'||!Number.isFinite(Date.parse(v.t))||typeof v.k!=='string'||v.k.length>40||!isUuid(v.i))throw Error('invalid_cursor');
  return {a:v.a,b:v.b,t:v.t,k:v.k,i:v.i};
}
export function workQueueHref(path:string,filter:Record<string,string>,cursor?:WorkCursor|null) {
  const q=new URLSearchParams(filter);if(cursor)q.set('cursor',JSON.stringify(cursor));
  return `${path}?${q}`;
}
export const supportStates = ['open','assigned','waiting_member','waiting_internal','resolved','closed'] as const;
export const supportPriorities = ['low','normal','high','critical'] as const;
export type SupportFilters = { queue:string; owner:string; priority:string; afterDue:string|null; afterId:string|null };
export function supportFilters(params:Record<string,string|undefined>):SupportFilters|null {
  const {queue='open',owner='all',priority='all',afterDue,afterId}=params;
  if(!['open','all','resolved','closed'].includes(queue)||!['all','mine','unassigned'].includes(owner)||!['all',...supportPriorities].includes(priority))return null;
  if(!!afterDue!==!!afterId || (afterDue&&(!isUuid(afterId)||afterDue.length>40||!Number.isFinite(Date.parse(afterDue)))))return null;
  return {queue,owner,priority,afterDue:afterDue??null,afterId:afterId??null};
}
export function supportQueueHref(filters:SupportFilters,next?:{sla_due_at:string;support_case_id:string}) {
  const q=new URLSearchParams({queue:filters.queue,owner:filters.owner,priority:filters.priority});
  if(next){q.set('afterDue',next.sla_due_at);q.set('afterId',next.support_case_id);}
  return `/support/cases?${q}`;
}
// Only allowlisted, actionable messages leave the server. Never expose SQL,
// submitted reasons, member data, keys or exception text to client telemetry.
export function workflowFailure(code:string,field?:string):WorkflowResult {
  const messages:Record<string,string>={
    mfa_required:'Complete MFA in a separate tab, then retry. Your inputs are still here.',
    forbidden:'Your current staff access cannot perform this action. Your inputs have not been saved.',
    conflict:'This case changed since you opened it. Reload the current record before making another decision.',
    invalid_input:'Check the indicated field and submit again.',
    rate_limited:'Too many requests. Wait before trying again; your inputs are still here.',
    independent_operator_required:'This decision requires an independent operator.',
    retry_mismatch:'These inputs differ from an already recorded operation. Reload and review the current record.',
    not_found:'The record is no longer available or actionable. Reload the queue.',
  };
  return messages[code]?{status:'error',message:messages[code],...(field?{field}:{})}:
    {status:'unknown',message:'The result could not be confirmed. Your inputs are retained. Check the current record and audit trail before retrying; do not assume nothing changed.'};
}
