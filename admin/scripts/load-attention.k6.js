// PREPARED, NOT RUN. Explicitly approved staging/local synthetic workload only.
// k6 run scripts/load-attention.k6.js
// ADMIN_LOAD_ENV=staging; ADMIN_LOAD_ORIGIN=https://approved-staging.supabase.co
// ADMIN_LOAD_APPROVED_HOST=approved-staging.supabase.co
// ADMIN_LOAD_PUBLISHABLE_KEY=...; ADMIN_LOAD_SESSIONS_FILE=/private/path/sessions.json
// sessions.json: [{"access_token":"authenticated synthetic staff JWT"}, ...]
// At least 100 DIFFERENT synthetic staff accounts with live sessions. Never use
// production staff tokens. Do not upload this file or include it in artifacts.
import http from 'k6/http';
import {sleep,check} from 'k6';
import encoding from 'k6/encoding';
import {SharedArray} from 'k6/data';
import {Rate} from 'k6/metrics';
const validSummary=new Rate('valid_attention_summary');
const origin=__ENV.ADMIN_LOAD_ORIGIN;
if(__ENV.ADMIN_LOAD_ENV!=='staging'||!origin)throw new Error('Explicit synthetic staging workload configuration required');
const match=/^(https?):\/\/([a-z0-9.-]+)(?::([0-9]+))?$/.exec(origin);
if(!match||match[2]!==__ENV.ADMIN_LOAD_APPROVED_HOST||match[1]!=='https'&&!['127.0.0.1','localhost'].includes(match[2]))throw new Error('Approved host and secure transport required');
function claims(token) {try{return JSON.parse(encoding.b64decode(token.split('.')[1],'rawurl','s'));}catch{throw new Error('Invalid synthetic session input');}}
const key=__ENV.ADMIN_LOAD_PUBLISHABLE_KEY??'';
if(!key.startsWith('sb_publishable_')&&claims(key).role!=='anon')throw new Error('Only a publishable or legacy anon API key is allowed');
const sessions=new SharedArray('synthetic staff sessions',()=>JSON.parse(open(__ENV.ADMIN_LOAD_SESSIONS_FILE)));
const accounts=new Set(),sessionIds=new Set();
if(sessions.length!==100)throw new Error('Exactly 100 synthetic sessions required');
for(const session of sessions) {
 const c=claims(session.access_token);
 if(c.role!=='authenticated'||c.is_anonymous===true||typeof c.sub!=='string'||typeof c.session_id!=='string'||typeof c.exp!=='number'||!Number.isFinite(c.exp)||accounts.has(c.sub)||sessionIds.has(c.session_id)||c.exp*1000<Date.now()+40*60*1000)throw new Error('Distinct, authenticated, sufficiently long-lived synthetic sessions required');
 accounts.add(c.sub);sessionIds.add(c.session_id);
}
export const options={scenarios:{staff:{executor:'ramping-vus',stages:[{duration:'2m',target:100},{duration:'30m',target:100},{duration:'2m',target:0}],gracefulRampDown:'30s'}},
 thresholds:{http_req_duration:['p(95)<500'],http_req_failed:['rate<0.01'],valid_attention_summary:['rate>0.99']},
 // Stable endpoint name only; no actor/session/token metric tags.
 systemTags:['status','method','name','scenario','expected_response'],discardResponseBodies:false};
export default function() {
 if(__ITER===0)sleep(Math.random()*30);
 const response=http.post(`${origin}/rest/v1/rpc/admin_staff_attention`,'{}',{headers:{apikey:key,Authorization:`Bearer ${sessions[__VU-1].access_token}`,'Content-Type':'application/json'},timeout:'6s',tags:{name:'staff-attention'}});
 let shape=false;try{
  const data=response.json(),now=Date.now(),fresh=value=>typeof value==='string'&&Number.isFinite(Date.parse(value))&&now-Date.parse(value)>=-60000&&now-Date.parse(value)<120000;
  shape=data&&data.enabled===true&&Number.isInteger(data.unread_count)&&data.unread_count>=0&&data.unread_count<=99
   &&typeof data.unread_more==='boolean'&&fresh(data.generated_at)&&fresh(data.worker_at)&&Array.isArray(data.queues)
   &&data.queues.every(q=>q&&Number.isInteger(q.count)&&q.count>=0&&q.stale===false&&fresh(q.measured_at));
 }catch{}
 validSummary.add(check(response,{'authorized summary available':r=>r.status===200&&shape}));
 sleep(30);
}
