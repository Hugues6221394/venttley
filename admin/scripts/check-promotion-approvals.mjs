// Prepared for deferred verification; synthetic adapters, never a live database.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
let enabled=false,role='super_admin',active=true,aal='aal2',session=true,limited=false,failure='',calls=[];
async function load(path,deps={}){
 const exports={};vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
 exports,Error,Date,Number,Object,Array,Set,FormData,URLSearchParams,process:{env:{get ADMIN_PROMOTION_APPROVALS_UI(){return enabled?'true':'false';}}},
 require:name=>{assert(name in deps,`Unexpected import ${name}`);return deps[name];},
 });return exports;
}
const id='1a792000-0000-4000-8000-000000000001';
const identity={isUuid:v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)};
const cursor=await load('../lib/staff-invitation-model.ts');
const model=await load('../lib/promotion-model.ts',{'./staff-invitation-model':cursor,'./inbox-model':identity});
assert.equal(model.promotionFilters({}).query,'');
for(const q of [['staff'],'email@example.invalid','x'.repeat(25),'%'])assert.equal(model.promotionFilters({q}),null);
assert.equal(model.promotionFilters({beforeId:id}),null);
assert.equal(model.promotionFilters({source:id}).source,id);
for(const params of [{source:'bad'},{source:[id]},{source:id,q:'staff'},{source:id,beforeAt:'2026-10-01T00:00:00Z',beforeId:id}])assert.equal(model.promotionFilters(params),null);
assert.equal(model.parsePromotionRegister({enabled:true,measured_at:'bad',items:[]}),null);
assert.equal(model.parsePromotionRegister({enabled:false}).enabled,false);
assert.equal(model.parsePromotionCandidates([{}]),null);
const validate=await load('../lib/validate.ts');
const workflow=await load('../lib/workflow-model.ts',{'./inbox-model':identity});
const server={createSsrClient:async()=>({auth:{getUser:async()=>({data:{user:session?{id}:null}}),mfa:{getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:aal},error:null})}}})};
const actor=await load('../lib/operational-actions.ts',{'server-only':{},'@/lib/supabase/server':server,'@/lib/staff':{activeStaffRole:async(_db,_id,roles)=>active&&roles.includes(role)?role:null},'@/lib/guard':{limitAction:async()=>{if(limited)throw Error('rate_limited');}}});
const governance=await load('../lib/governance-action.ts',{'server-only':{},'./validate':validate,'./workflow-model':workflow,'./supabase/server':server,'./operational-actions':actor,'./audit':{rpc:async(fn,params)=>{calls.push({fn,params});if(failure)throw Error(failure.replace('{fn}',fn));}}});
const actions=await load('../lib/promotion-actions.ts',{'./governance-action':governance,'./validate':validate});
function fd(extra={}){const f=new FormData();for(const [k,v]of Object.entries({operation_id:id,target_id:id,approval_id:id,version:'1',command:'approve',reason_code:'succession',...extra}))f.set(k,v);return f;}
function reset(){enabled=true;role='super_admin';active=true;aal='aal2';session=true;limited=false;failure='';calls=[];}
for(const action of [actions.requestPromotion,actions.commandPromotion]){
 reset();enabled=false;assert.equal((await action(fd())).status,'error');assert.equal(calls.length,0);
 for(const candidate of ['super_admin','admin','moderator','support','analyst','read_only_auditor']){
  reset();role=candidate;assert.equal((await action(fd())).status,candidate==='super_admin'?'success':'error');assert.equal(calls.length,candidate==='super_admin'?1:0);
 }
 for(const denied of ['session','active','aal','limited']){
  reset();if(denied==='session')session=false;if(denied==='active')active=false;if(denied==='aal')aal='aal1';if(denied==='limited')limited=true;
  assert.equal((await action(fd())).status,'error');assert.equal(calls.length,0);
 }
 reset();assert.equal((await action(fd({operation_id:'bad'}))).status,'error');assert.equal(calls.length,0);
 reset();failure='secret provider timeout';const unknown=await action(fd());assert.equal(unknown.status,'unknown');assert(!unknown.message.includes('secret'));
 for(const code of ['promotion_expired','promotion_target_changed','promotion_authority_changed','promotion_target_not_ready','promotion_conflict']){
  reset();failure=`{fn}: ${code}`;assert.equal((await action(fd())).status,'error');
 }
}
for(const command of ['approve','reject','cancel','execute']){reset();await actions.commandPromotion(fd({command}));assert.equal(calls[0].params.p_command,command);assert(!('p_target' in calls[0].params));}
reset();assert.equal((await actions.commandPromotion(fd({command:'promote_anyone'}))).status,'error');assert.equal(calls.length,0);
console.log('PASS promotion action/model gates with synthetic adapters; database enforcement and concurrent execution still need pgTAP/live tests');
