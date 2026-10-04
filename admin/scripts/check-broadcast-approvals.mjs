// Prepared for deferred verification. Synthetic adapters; no live backend.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
let enabled=true,role='admin',active=true,session=true,aal='aal2',failure='',calls=[];
async function load(path,deps={}) {
 const exports={};
 vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
  exports,Error,Date,Number,Object,Array,Set,FormData,URLSearchParams,
  process:{env:{get ADMIN_BROADCAST_APPROVALS_UI(){return enabled?'true':'false';}}},
  require:name=>{assert(name in deps,`Unexpected import ${name}`);return deps[name];},
 });return exports;
}
const id='1b792000-0000-4000-8000-000000000001';
const identity={isUuid:v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)};
const cursors=await load('../lib/staff-invitation-model.ts');
const model=await load('../lib/broadcast-approval-model.ts',{'./inbox-model':identity,'./staff-invitation-model':cursors});
assert.equal(model.parseBroadcastApprovalRegister({enabled:false}).enabled,false);
assert.equal(model.parseBroadcastApprovalRegister({enabled:true,measured_at:'bad',items:[]}),null);
assert.equal(model.parseBroadcastApprovalRegister({enabled:true,measured_at:'2026-10-01T00:00:00Z',items:[{}]}),null);
assert.equal(model.broadcastApprovalCursor({beforeId:id}),null);
assert.equal(model.broadcastApprovalCursor({source:id}).source,id);
for(const params of [{source:'bad'},{source:[id]},{source:id,beforeAt:'2026-10-01T00:00:00Z',beforeId:id}])assert.equal(model.broadcastApprovalCursor(params),null);
const item={approval_id:id,title:'Synthetic notice',body:'Plain text only',urgency:'info',state:'pending',version:1,
 created_at:'2026-10-01T00:00:00.123456Z',expires_at:'2026-10-02T00:00:00Z',publication_expires_at:'2026-10-03T00:00:00Z',
 approved_at:null,published_at:null,broadcast_id:null,publication_active:null,requester_name:'Operator',approver_name:null,expired:false,requested_by_me:true};
assert(model.parseBroadcastApprovalRegister({enabled:true,measured_at:item.created_at,items:[item]}));
assert.equal(new URLSearchParams(model.broadcastApprovalHref(item).split('?')[1]).get('beforeAt'),item.created_at);
for(const bad of [{version:0},{body:null},{state:'sent'},{publication_active:'yes'},{broadcast_id:'bad'}])
 assert.equal(model.parseBroadcastApprovalRegister({enabled:true,measured_at:item.created_at,items:[{...item,...bad}]}),null);
const validate=await load('../lib/validate.ts');
const workflow=await load('../lib/workflow-model.ts',{'./inbox-model':identity});
const server={createSsrClient:async()=>({auth:{getUser:async()=>({data:{user:session?{id}:null}}),mfa:{getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:aal},error:null})}}})};
const actor=await load('../lib/operational-actions.ts',{'server-only':{},'@/lib/supabase/server':server,'@/lib/staff':{activeStaffRole:async(_db,_id,roles)=>active&&roles.includes(role)?role:null},'@/lib/guard':{limitAction:async()=>{}}});
const governance=await load('../lib/governance-action.ts',{'server-only':{},'./validate':validate,'./workflow-model':workflow,'./supabase/server':server,'./operational-actions':actor,
 './audit':{rpc:async(fn,params)=>{calls.push({fn,params});if(failure)throw Error(failure.replace('{fn}',fn));}}});
const actions=await load('../lib/broadcast-approval-actions.ts',{'./governance-action':governance,'./validate':validate});
function fd(extra={}) {const f=new FormData();for(const[k,v]of Object.entries({operation_id:id,approval_id:id,version:'1',command:'approve',title:'Synthetic notice',body:'Plain text',urgency:'info',expires_at:'2026-10-03T12:00',...extra}))f.set(k,v);return f;}
function reset(){enabled=true;role='admin';active=true;session=true;aal='aal2';failure='';calls=[];}
for(const action of [actions.requestBroadcastApproval,actions.commandBroadcastApproval,actions.stopApprovedBroadcast]) {
 for(const r of ['super_admin','admin','moderator','support','analyst','read_only_auditor']) {
  reset();role=r;const allowed=['super_admin','admin'].includes(r);
  assert.equal((await action(fd())).status,allowed?'success':'error');assert.equal(calls.length,allowed?1:0);
 }
 for(const denied of ['flag','active','session','mfa']) {
  reset();if(denied==='flag')enabled=false;if(denied==='active')active=false;if(denied==='session')session=false;if(denied==='mfa')aal='aal1';
  assert.equal((await action(fd())).status,'error');assert.equal(calls.length,0);
 }
 reset();assert.equal((await action(fd({operation_id:'bad'}))).status,'error');assert.equal(calls.length,0);
 reset();failure='private backend detail';const unknown=await action(fd());assert.equal(unknown.status,'unknown');assert(!unknown.message.includes('private backend'));
 for(const code of ['broadcast_conflict','broadcast_expired','broadcast_authority_changed','broadcast_session_unavailable','broadcast_approval_required']) {
  reset();failure=`{fn}: ${code}`;assert.equal((await action(fd())).status,'error');
 }
}
reset();await actions.requestBroadcastApproval(fd({user_id:'forged',audience:'tribe',scheduled_for:'tomorrow'}));
assert(!('p_user_id' in calls[0].params));assert(!('p_audience' in calls[0].params));assert(!('p_scheduled_for' in calls[0].params));
assert.equal(calls[0].params.p_expires_at,'2026-10-03T12:00:00.000Z');
for(const invalid of [{title:''},{body:'x'.repeat(1001)},{urgency:'emergency'},{expires_at:'2026-02-30T12:00'}]) {
 reset();assert.equal((await actions.requestBroadcastApproval(fd(invalid))).status,'error');assert.equal(calls.length,0);
}
reset();assert.equal((await actions.commandBroadcastApproval(fd({command:'edit'}))).status,'error');assert.equal(calls.length,0);
console.log('PASS synthetic broadcast action/model checks; no claim of database, browser or delivery verification');
