// Run in an independent monitor, NEVER inside the worker it observes.
// No browser credentials, content, URLs, raw responses or error messages logged.
import {pathToFileURL} from 'node:url';
export function assessNotificationHealth(v, now=Date.now()) {
 const unknown={status:'unknown',reasons:['invalid_or_stale_monitor_response']};
 const record=x=>!!x&&typeof x==='object'&&!Array.isArray(x);
 const time=x=>typeof x==='string'&&x.length<=40&&Number.isFinite(Date.parse(x));
 const stale=x=>!time(x)||Date.parse(x)<now-120000||Date.parse(x)>now+60000;
 const optionalTime=x=>x===null||time(x);
 if(!record(v)||stale(v.checked_at)||['enabled','worker_stale','job_monitor_stale','has_failed_events','has_overdue_pending'].some(k=>typeof v[k]!=='boolean'))return unknown;
 const d=v.incident_deadlines;
 if(!record(d)||['enabled','scheduler_active','worker_stale'].some(k=>typeof d[k]!=='boolean')||
  !optionalTime(d.succeeded_at)||!optionalTime(d.oldest_unprocessed_due_at)||
  !(d.enqueued===null||Number.isInteger(d.enqueued)&&d.enqueued>=0&&d.enqueued<=2100)||
  !(d.backlog_overdue===null||typeof d.backlog_overdue==='boolean')||
  !(d.batch_max_lag_seconds===null||typeof d.batch_max_lag_seconds==='number'&&Number.isFinite(d.batch_max_lag_seconds)&&d.batch_max_lag_seconds>=0)||
  d.enabled&&!v.enabled)return unknown;
 if(!v.enabled)return {status:'disabled',reasons:['notification_pilot_disabled']};
 const reasons=[];
 if(v.worker_stale)reasons.push('delivery_worker_stale');
 if(v.job_monitor_stale)reasons.push('job_snapshot_stale');
 if(v.has_failed_events)reasons.push('failed_delivery_events');
 if(v.has_overdue_pending)reasons.push('delivery_backlog_overdue');
 if(d.enabled){
  if(!d.scheduler_active)reasons.push('incident_deadline_scheduler_inactive');
  if(d.worker_stale||stale(d.succeeded_at))reasons.push('incident_deadline_worker_stale');
  if(d.enqueued===null||d.backlog_overdue===null)reasons.push('incident_deadline_snapshot_unknown');
  if(d.backlog_overdue||d.oldest_unprocessed_due_at!==null&&Date.parse(d.oldest_unprocessed_due_at)<now-300000)reasons.push('incident_deadline_backlog_overdue');
 }
 return {status:reasons.length?'attention':'healthy',reasons};
}
export async function runMonitor(env=process.env,request=fetch){
 try{
  const url=new URL(env.NOTIFICATION_MONITOR_URL),key=env.NOTIFICATION_MONITOR_SERVICE_KEY;
  if((url.protocol!=='https:'&&!(url.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(url.hostname)))||
   url.username||url.password||url.search||url.hash||url.pathname!=='/'||!key)return {status:'unknown',reasons:['invalid_monitor_configuration']};
  const response=await request(new URL('/rest/v1/rpc/staff_notification_monitor',url),{
   method:'POST',headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'},
   body:'{}',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(8000),
  });
  if(!response.ok)return {status:'unknown',reasons:['monitor_request_failed']};
  if(!response.body)return {status:'unknown',reasons:['invalid_monitor_response']};
  const reader=response.body.getReader(),decoder=new TextDecoder();let bytes=0,body='';
  try{
   while(true){
    const {done,value}=await reader.read();if(done)break;
    bytes+=value.byteLength;
    if(bytes>16384){await reader.cancel();return {status:'unknown',reasons:['invalid_monitor_response']};}
    body+=decoder.decode(value,{stream:true});
   }
   body+=decoder.decode();
  }finally{reader.releaseLock();}
  return assessNotificationHealth(JSON.parse(body));
 }catch{return {status:'unknown',reasons:['monitor_unavailable']};}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const result=await runMonitor();console.log(JSON.stringify(result));
 process.exitCode=result.status==='healthy'?0:result.status==='attention'?1:2;
}
