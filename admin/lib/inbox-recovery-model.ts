import { inboxCopy, isUuid, type StaffInboxKind } from './inbox-model';

export const recoveryReasons = {
  transient_resolved: 'Transient issue resolved',
  configuration_fixed: 'Configuration corrected',
  reviewed_retry: 'Reviewed and approved for retry',
} as const;
export type RecoveryCursor = { at:string; id:string };
export type FailedNotice = { event_id:string; kind:StaffInboxKind; severity:'info'|'warning'|'critical'; attempts:number; last_error_code:string|null; created_at:string };
export type InboxHealth = { enabled:boolean; worker_at:string|null; worker_stale:boolean; pending:number; failed:number; oldest_pending_at:string|null };
export type NotificationHistory = { measured_at:string; jobs_enabled:boolean; reports_enabled:boolean;
  jobs:{queue:'push'|'email'|'media';count:number|null;has_more:boolean;measured_at:string|null}[];
  hours:{hour:string;batches:number;delivered_events:number;failed_attempts:number;max_delivery_lag_seconds:number|null;last_batch_at:string}[] };
export type RecoverySnapshot = { at:string; health:InboxHealth|null; items:FailedNotice[]|null; next:RecoveryCursor|null; observability?:NotificationHistory|null };
const timestamp = (v:unknown):v is string => typeof v==='string' && v.length<=40 && Number.isFinite(Date.parse(v));
const count = (v:unknown):v is number => typeof v==='number' && Number.isSafeInteger(v) && v>=0;
const record = (v:unknown):v is Record<string,unknown> => !!v && typeof v==='object' && !Array.isArray(v);
export function parseNotificationHistory(v:unknown):NotificationHistory|null {
  if(!record(v)||!timestamp(v.measured_at)||typeof v.jobs_enabled!=='boolean'||typeof v.reports_enabled!=='boolean'||
    !Array.isArray(v.jobs)||v.jobs.length!==3||!Array.isArray(v.hours)||v.hours.length>24)return null;
  const jobs:NotificationHistory['jobs']=[],hours:NotificationHistory['hours']=[],seen=new Set<string>();
  for(const row of v.jobs){
    if(!record(row)||typeof row.queue!=='string'||!['push','email','media'].includes(row.queue)||seen.has(row.queue)||
      !(row.count===null||count(row.count)&&row.count<=1000)||typeof row.has_more!=='boolean'||
      !(row.measured_at===null||timestamp(row.measured_at)))return null;
    seen.add(row.queue);jobs.push({queue:row.queue as 'push'|'email'|'media',count:row.count,has_more:row.has_more,measured_at:row.measured_at});
  }
  seen.clear();
  for(const row of v.hours){
    if(!record(row)||!timestamp(row.hour)||seen.has(row.hour)||!timestamp(row.last_batch_at)||!count(row.batches)||
      !count(row.delivered_events)||!count(row.failed_attempts)||!(row.max_delivery_lag_seconds===null||typeof row.max_delivery_lag_seconds==='number'&&Number.isFinite(row.max_delivery_lag_seconds)&&row.max_delivery_lag_seconds>=0))return null;
    seen.add(row.hour);hours.push({hour:row.hour,batches:row.batches,delivered_events:row.delivered_events,failed_attempts:row.failed_attempts,max_delivery_lag_seconds:row.max_delivery_lag_seconds,last_batch_at:row.last_batch_at});
  }
  return {measured_at:v.measured_at,jobs_enabled:v.jobs_enabled,reports_enabled:v.reports_enabled,jobs,hours};
}
export function recoveryCursor(params:URLSearchParams):RecoveryCursor|null|undefined {
  const at=params.get('afterAt'),id=params.get('afterId');
  if(at===null&&id===null)return undefined;
  return timestamp(at)&&isUuid(id)?{at,id}:null;
}
export function parseInboxHealth(v:unknown):InboxHealth|null {
  if(!record(v)||typeof v.enabled!=='boolean'||typeof v.worker_stale!=='boolean'||!count(v.pending)||!count(v.failed)||
    !(v.worker_at===null||timestamp(v.worker_at))||!(v.oldest_pending_at===null||timestamp(v.oldest_pending_at)))return null;
  return {enabled:v.enabled,worker_at:v.worker_at,worker_stale:v.worker_stale,pending:v.pending,failed:v.failed,oldest_pending_at:v.oldest_pending_at};
}
export function parseFailedNotices(v:unknown):FailedNotice[]|null {
  if(!Array.isArray(v)||v.length>31)return null;
  const rows:FailedNotice[]=[];const seen=new Set<string>();
  for(const row of v){
    if(!record(row)||!isUuid(row.event_id)||seen.has(row.event_id)||typeof row.kind!=='string'||!Object.hasOwn(inboxCopy,row.kind)||
      !['info','warning','critical'].includes(String(row.severity))||!count(row.attempts)||!timestamp(row.created_at)||
      !(row.last_error_code===null||(typeof row.last_error_code==='string'&&/^[A-Z0-9]{5}$/.test(row.last_error_code))))return null;
    seen.add(row.event_id);
    rows.push({event_id:row.event_id,kind:row.kind as StaffInboxKind,severity:row.severity as FailedNotice['severity'],attempts:row.attempts,last_error_code:row.last_error_code,created_at:row.created_at});
  }
  return rows;
}
export function parseRecoverySnapshot(v:unknown):RecoverySnapshot|null {
  if(!record(v)||!timestamp(v.at))return null;
  const health=parseInboxHealth(v.health),items=parseFailedNotices(v.items);
  if(v.health!==null&&!health||v.items!==null&&!items||items&&items.length>30)return null;
  let next:RecoveryCursor|null=null;
  if(v.next!==null){if(!record(v.next)||!timestamp(v.next.at)||!isUuid(v.next.id)||!items?.length)return null;next={at:v.next.at,id:v.next.id};}
  return {at:v.at,health,items,next,...(Object.hasOwn(v,'observability')?{observability:parseNotificationHistory(v.observability)}:{})};
}
