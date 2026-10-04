import 'server-only';
import { getRenderStaff, createSsrClient } from './supabase/server';
import { hasModernShell } from './shell-rollout';
import { supportFilters,workCursor,type WorkCursor } from './workflow-model';
import type { SupportCase } from './governance';

export async function workflowUIEnabled() {
  const staff=await getRenderStaff();
  return process.env.ADMIN_WORKFLOWS_UI==='true'&&hasModernShell(staff?.role,process.env.ADMIN_SHELL_V2,process.env.ADMIN_SHELL_V2_ROLES);
}
export type StaffOption={staff_id:string;display_name:string;username:string};
export type CursorRow={_cursor:WorkCursor};
export async function dailyWorkflowQueue<T>(fn:'admin_appeal_work_queue'|'admin_safety_work_queue'|'admin_case_work_queue',params:Record<string,unknown>,cursor?:string) {
  try {
  const db=await createSsrClient();
  const {data,error}=await db.rpc(fn,{...params,p_limit:31,p_cursor:workCursor(cursor)}).abortSignal(AbortSignal.timeout(8000));
  if(error)throw new Error('Workflow queue unavailable');
  const rows=(data??[]) as (T&CursorRow)[];
  return {rows:rows.slice(0,30),next:rows.length>30?rows[29]._cursor:null,error:false};
  }catch{return {rows:[] as (T&CursorRow)[],next:null,error:true};}
}
export type SupportEvent={event_id:string;event_kind:string;actor_name:string|null;from_status:string|null;to_status:string|null;priority:string|null;assigned:boolean|null;created_at:string};
export async function supportHistory(id:string,time?:string,event?:string) {
  try {
    const db=await createSsrClient();
    const {data,error}=await db.rpc('admin_support_history',{p_case:id,p_before_time:time??null,p_before_id:event??null,p_limit:31}).abortSignal(AbortSignal.timeout(8000));
    if(error)throw Error('unavailable');const rows=(data??[]) as SupportEvent[];
    return {rows:rows.slice(0,30),next:rows.length>30?rows[29]:null,error:false};
  }catch{return {rows:[] as SupportEvent[],next:null,error:true};}
}
export async function supportWorkQueue(params:Record<string,string|undefined>) {
  const filters=supportFilters(params);
  if(!filters)return {data:[] as SupportCase[],error:'Invalid queue filters. Reset the filters to continue.',filters:null,next:null};
  try {
  const db=await createSsrClient();
  const {data,error}=await db.rpc('admin_support_work_queue',{
    p_queue:filters.queue,p_owner:filters.owner,p_priority:filters.priority,
    p_after_due:filters.afterDue,p_after_id:filters.afterId,p_limit:31,
  }).abortSignal(AbortSignal.timeout(8000));
  const rows=(data??[]) as SupportCase[];
  return {data:error?[]:rows.slice(0,30),error:error?'Support cases could not be verified. Retry without changing your filters.':null,
    filters,next:!error&&rows.length>30?rows[29]:null};
  } catch {
    return {data:[] as SupportCase[],error:'Support cases could not be verified. Retry without changing your filters.',filters,next:null};
  }
}
