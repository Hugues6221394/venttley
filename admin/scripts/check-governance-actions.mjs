import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';

async function load(path, dependencies={}) {
  const source=await readFile(new URL(path,import.meta.url),'utf8');
  const exports={};
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
    exports,Error,FormData,Date,Number,Object,Set,
    require:name=>{assert(name in dependencies,`Unexpected dependency ${name}`);return dependencies[name];},
  });return exports;
}
const validate=await load('../lib/validate.ts');
const model=await load('../lib/workflow-model.ts',{'./inbox-model':{isUuid:()=>true}});
let role,session,active,aal,limited,rpcFailure,calls;
function reset(){role='super_admin';session=true;active=true;aal='aal2';limited=false;rpcFailure=null;calls=[];}
const server={createSsrClient:async()=>({auth:{
  getUser:async()=>({data:{user:session?{id:'synthetic-actor'}:null}}),
  mfa:{getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:aal},error:null})},
}})};
const actor=await load('../lib/operational-actions.ts',{
  'server-only':{},'@/lib/supabase/server':server,
  '@/lib/staff':{activeStaffRole:async(_db,_id,roles)=>active&&roles.includes(role)?role:null},
  '@/lib/guard':{limitAction:async kind=>{assert.equal(kind,'destructive');if(limited)throw Error('rate_limited');}},
});
const governance=await load('../lib/governance-action.ts',{
  'server-only':{},'./validate':validate,'./workflow-model':model,'./supabase/server':server,'./operational-actions':actor,
  './audit':{rpc:async(name,args)=>{calls.push({name,args});if(rpcFailure)throw Error(rpcFailure.replace('{fn}',name));}},
});
const dependencies={'@/lib/governance-action':governance,'@/lib/validate':validate};
const recovery=await load('../app/(dashboard)/recovery-readiness/actions.ts',dependencies);
const legal=await load('../app/(dashboard)/legal-requests/actions.ts',dependencies);
const id='00000000-0000-4000-8000-000000000001';
function form(extra={}){
  const fd=new FormData();for(const [key,value]of Object.entries({
    operation_id:id,drill_id:id,request_id:id,environment:'isolated_restore',scheduled_at:'2032-02-29T12:30',
    expected_rpo_minutes:'0',expected_rto_minutes:'60',actual_rpo_minutes:'0',actual_rto_minutes:'60',
    checks_passed:'10',checks_total:'10',outcome:'passed',evidence_hash:'a'.repeat(64),
    request_type:'court_order',due_at:'2096-02-29T12:30',jurisdiction:'rw',reference_hash:'b'.repeat(64),
    scope_code:'account_metadata',decision:'approve',manifest_hash:'C'.repeat(64),requester_verified:'on',
    reason_code:'valid_authority',receipt_hash:'d'.repeat(64),...extra,
  }))fd.set(key,value);return fd;
}
const operations=[
  [recovery.scheduleRecoveryDrill,true], [recovery.completeRecoveryDrill,true], [recovery.verifyRecoveryDrill,false],
  [legal.createLegalRequest,true], [legal.decideLegalRequest,false], [legal.fulfilLegalRequest,false],
];
for(const [action,adminAllowed]of operations){
  for(const candidate of ['super_admin','admin','moderator','support','analyst','read_only_auditor']){
    reset();role=candidate;const result=await action(form());const allowed=candidate==='super_admin'||candidate==='admin'&&adminAllowed;
    assert.equal(result.status,allowed?'success':'error');assert.equal(calls.length,allowed?1:0);
    if(allowed)assert.equal(calls[0].args.p_operation,id,'keep existing server receipt key');
  }
  for(const state of ['missing','suspended','mfa','rate']){
    reset();if(state==='missing')session=false;if(state==='suspended')active=false;if(state==='mfa')aal='aal1';if(state==='rate')limited=true;
    assert.equal((await action(form())).status,'error');assert.equal(calls.length,0);
  }
  reset();assert.equal((await action(form({operation_id:'invalid'}))).status,'error');assert.equal(calls.length,0);
  for(const error of ['timeout secret-payload','{fn}: unfamiliar error: mfa_required secret-payload']){
    reset();rpcFailure=error;const result=await action(form());assert.equal(result.status,'unknown');assert.equal(calls.length,1);
    assert(!JSON.stringify(result).includes('secret-payload'));
  }
  for(const error of ['not_authorized','idempotency_payload_mismatch','independent_verifier_required',
    'aal2_required: this action requires a completed MFA step-up, not just a signed-in session']){
    reset();rpcFailure=`{fn}: ${error}`;assert.equal((await action(form())).status,'error');assert.equal(calls.length,1);
  }
}
for(const value of ['', '2031-02-29T12:00', '2032-02-30T12:00', '2032-13-01T12:00', '2032-01-01T24:00', '2032-01-01', '2032-01-01T12:00Z']){
  reset();const result=await recovery.scheduleRecoveryDrill(form({scheduled_at:value}));assert.equal(result.field,'scheduled_at');assert.equal(calls.length,0);
}
reset();await recovery.scheduleRecoveryDrill(form());assert.equal(calls[0].args.p_scheduled_at,'2032-02-29T12:30:00.000Z');
for(const field of ['actual_rpo_minutes','actual_rto_minutes','checks_passed','checks_total']){
  for(const value of ['', ' ', '-1', '1.5', '1e2']){
    reset();const result=await recovery.completeRecoveryDrill(form({[field]:value}));assert.equal(result.field,field);assert.equal(calls.length,0);
  }
}
reset();assert.equal((await recovery.completeRecoveryDrill(form({checks_passed:'11'}))).field,'checks_passed');assert.equal(calls.length,0);
for(const [field,value]of [['manifest_hash',''],['manifest_hash','invalid'],['requester_verified',''],['reason_code','withdrawn']]){
  reset();assert.equal((await legal.decideLegalRequest(form({[field]:value}))).field,field);assert.equal(calls.length,0);
}
reset();assert.equal((await legal.decideLegalRequest(form({decision:'reject',manifest_hash:'',requester_verified:'',reason_code:'withdrawn'}))).status,'success');
reset();await legal.createLegalRequest(form());assert.equal(calls[0].args.p_jurisdiction,'RW');
for(const [field,value]of [['due_at','2020-01-01T12:00'],['jurisdiction','<script>'],['reference_hash','invalid']]){
  reset();assert.equal((await legal.createLegalRequest(form({[field]:value}))).field,field);assert.equal(calls.length,0);
}
for(const route of ['legal-requests','recovery-readiness']){
  const page=await readFile(new URL(`../app/(dashboard)/${route}/page.tsx`,import.meta.url),'utf8');
  assert.equal((page.match(/<WorkflowForm /g)||[]).length,3);assert.equal((page.match(/blockUncertainRetry/g)||[]).length,3);
  assert(!page.includes('OperationResult'),'query strings must not forge a successful mutation notice');
  assert(page.includes('(UTC)'));assert(!page.includes('.error}</DataWarning>'),'no raw database error in the UI');
}
console.log('PASS governance actions: six actions, six-role matrices, revoked/MFA/rate refusals, input validation, explicit UTC, safe uncertain outcomes and existing receipt keys (synthetic adapters; not live database proof)');
