// Synthetic data-access tests. These do not exercise PostgreSQL or browser UI.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
let role='super_admin',active=true,session=true,enabled=true,response=null,failed=false,timedOut=false,calls=[];
async function load(path,deps={}) {
 const exports={};
 vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
  exports,Date,Number,Object,Array,Set,URLSearchParams,AbortSignal,
  process:{env:{get ADMIN_PROMOTION_APPROVALS_UI(){return enabled?'true':'false';},get ADMIN_BROADCAST_APPROVALS_UI(){return enabled?'true':'false';}}},
  require:name=>{assert(name in deps,`Unexpected import ${name}`);return deps[name];},
 });return exports;
}
const id='1c792000-0000-4000-8000-000000000001',other='1c792000-0000-4000-8000-000000000002';
const inbox=await load('../lib/inbox-model.ts');
const cursor=await load('../lib/staff-invitation-model.ts');
const promotion=await load('../lib/promotion-model.ts',{'./inbox-model':inbox,'./staff-invitation-model':cursor});
const broadcast=await load('../lib/broadcast-approval-model.ts',{'./inbox-model':inbox,'./staff-invitation-model':cursor});
const db={auth:{getUser:async()=>({data:{user:session?{id}:null}})},rpc:(name,params)=>{
 calls.push({name,params});return {abortSignal:async signal=>{assert(signal instanceof AbortSignal);if(timedOut)throw new DOMException('Synthetic timeout','TimeoutError');return {data:response,error:failed?{message:'Private backend failure'}:null};}};
}};
const deps={'server-only':{},'./supabase/server':{createSsrClient:async()=>db},'./staff':{activeStaffRole:async(_db,_id,roles)=>active&&roles.includes(role)?role:null}};
const promotions=await load('../lib/promotions.ts',{...deps,'./promotion-model':promotion});
const broadcasts=await load('../lib/broadcast-approvals.ts',{...deps,'./broadcast-approval-model':broadcast});
const stamp='2026-10-01T00:00:00Z';
const common={approval_id:id,version:1,state:'pending',created_at:stamp,expires_at:stamp,approved_at:null,requester_name:'Operator',approver_name:null,expired:false,requested_by_me:false};
const p={...common,target_name:'Staff',target_role:'admin',reason_code:'succession',executed_at:null,targets_me:false};
const b={...common,title:'Synthetic public notice',body:'Not in the inbox',urgency:'info',publication_expires_at:stamp,published_at:null,broadcast_id:null,publication_active:null};
for(const [read,parse,item,roles] of [[promotions.readPromotions,promotion.promotionFilters,p,['super_admin']],[broadcasts.readBroadcastApprovals,broadcast.broadcastApprovalCursor,b,['super_admin','admin']]]) {
 const filter=parse({source:id});
 function reset(){role='super_admin';active=true;session=true;enabled=true;failed=false;timedOut=false;calls=[];response={enabled:true,measured_at:stamp,items:[item]};}
 for(const candidate of ['super_admin','admin','moderator','support','analyst','read_only_auditor']) {
  reset();role=candidate;const result=await read(filter);
  assert.equal(result!==null,roles.includes(candidate));assert.equal(calls.length,roles.includes(candidate)?1:0);
  if(result)assert.equal(calls[0].params.p_source,id);
 }
 for(const denied of ['active','session','flag']) {
  reset();if(denied==='active')active=false;if(denied==='session')session=false;if(denied==='flag')enabled=false;
  assert.equal(await read(filter),null);assert.equal(calls.length,0);
 }
 reset();response.items=[{...item,approval_id:other}];assert.equal(await read(filter),null,'never substitute another request');
 reset();response.items=[item,item];assert.equal(await read(filter),null,'exact source cannot yield a queue');
 reset();response.items=[];assert(await read(filter),'missing record is distinguishable from failure');
 reset();failed=true;assert.equal(await read(filter),null,'failure stays unknown');
 reset();timedOut=true;assert.equal(await read(filter),null,'timeout stays unknown');
 reset();response={enabled:false};assert(await read(filter),'database rollout remains independently visible');
}
console.log('PASS governance notice source filters and readers: exact record, no candidate scan on detail, six roles, revoked session/access, rollback and failures (synthetic adapters only)');
