import assert from 'node:assert/strict';
import {assessNotificationHealth,runMonitor} from './monitor-notifications.mjs';
const now=Date.now(),at=new Date(now).toISOString();
const good={checked_at:at,enabled:true,worker_stale:false,job_monitor_stale:false,has_failed_events:false,has_overdue_pending:false,
 incident_deadlines:{enabled:true,scheduler_active:true,succeeded_at:at,worker_stale:false,enqueued:0,oldest_unprocessed_due_at:null,backlog_overdue:false,batch_max_lag_seconds:null}};
assert.equal(assessNotificationHealth(good,now).status,'healthy');
assert.equal(assessNotificationHealth({...good,enabled:false,incident_deadlines:{...good.incident_deadlines,enabled:false}},now).status,'disabled');
for(const change of [{worker_stale:true},{scheduler_active:false},{succeeded_at:null},{succeeded_at:new Date(now+120000).toISOString()},{backlog_overdue:true},{oldest_unprocessed_due_at:new Date(now-360000).toISOString()},{enqueued:null}]){
 assert.equal(assessNotificationHealth({...good,incident_deadlines:{...good.incident_deadlines,...change}},now).status,'attention');
}
for(const key of ['worker_stale','job_monitor_stale','has_failed_events','has_overdue_pending'])assert.equal(assessNotificationHealth({...good,[key]:true},now).status,'attention');
for(const bad of [null,{}, {...good,checked_at:new Date(now-180000).toISOString()},{...good,incident_deadlines:null},
 {...good,incident_deadlines:{...good.incident_deadlines,enqueued:2101}}])assert.equal(assessNotificationHealth(bad,now).status,'unknown');
assert.equal(assessNotificationHealth({...good,secret:'do not log'},now).reasons.includes('do not log'),false);
const env={NOTIFICATION_MONITOR_URL:'http://127.0.0.1:54321',NOTIFICATION_MONITOR_SERVICE_KEY:'synthetic-key'};
assert.equal((await runMonitor(env,async(url,options)=>{
 assert.equal(url.pathname,'/rest/v1/rpc/staff_notification_monitor');assert.equal(options.redirect,'error');
 return new Response(JSON.stringify(good));
})).status,'healthy');
assert.equal((await runMonitor(env,async()=>{throw Error('sensitive exception');})).status,'unknown');
assert.equal((await runMonitor(env,async()=>new Response('secret',{status:403}))).status,'unknown');
assert.equal((await runMonitor(env,async()=>new Response('x'.repeat(16385)))).reasons[0],'invalid_monitor_response');
assert.equal((await runMonitor({...env,NOTIFICATION_MONITOR_URL:'http://remote.example'},async()=>{throw Error('must not fetch');})).reasons[0],'invalid_monitor_configuration');
console.log('PASS notification monitor: freshness, independent deadline health, disabled/unknown, safe failure and metadata-only output');
