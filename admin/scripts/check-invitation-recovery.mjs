// Prepared, not a live Auth or database test. Uses the real recovery action.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
let enabled=false,paused=false,calls=[];
async function load(path,deps={}){
 const exports={};vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
 exports,Error,Date,Number,Object,Array,FormData,process:{env:{get ADMIN_INVITATION_LEDGER_UI(){return enabled?'true':'false';},get ADMIN_STAFF_INVITES_DISABLED(){return paused?'true':'false';}}},
 require:name=>{assert(name in deps,`Unexpected import ${name}`);return deps[name];},
 });return exports;
}
const validate=await load('../lib/validate.ts');
const actions=await load('../lib/staff-invitation-actions.ts',{
 './validate':validate,
 './governance-action':{
  governanceInteger:(fd,key,min,max)=>validate.intInRange(fd,key,min,max),
  governanceAction:async(roles,fn,params,message)=>{assert.deepEqual(Array.from(roles),['super_admin']);calls.push({fn,params:params()});return {status:'success',message};},
 },
});
const id='1a790000-0000-4000-8000-000000000001';
function fd(command='reconcile',extra={}){const f=new FormData();for(const [k,v]of Object.entries({operation_id:id,invitation_id:id,version:'2',command,...extra}))f.set(k,v);return f;}
assert.equal((await actions.recoverStaffInvitation(fd())).status,'error');assert.equal(calls.length,0);
enabled=true;
for(const command of ['reconcile','cancel','complete_grant']){
 const result=await actions.recoverStaffInvitation(fd(command));assert.equal(result.status,'success');
 assert.equal(calls.at(-1).fn,'admin_recover_staff_invitation');assert.equal(calls.at(-1).params.p_command,command);
 assert.equal(calls.at(-1).params.p_version,2);assert.equal(calls.at(-1).params.p_invitation,id);
 assert(!('p_user' in calls.at(-1).params));assert(!('p_role' in calls.at(-1).params),'target and role are server-derived');
}
await assert.rejects(actions.recoverStaffInvitation(fd('resend')),/command/);
await assert.rejects(actions.recoverStaffInvitation(fd('cancel',{invitation_id:'bad'})),/invitation_id/);
await assert.rejects(actions.recoverStaffInvitation(fd('cancel',{version:'0'})),/version/);
paused=true;const before=calls.length;
assert.equal((await actions.recoverStaffInvitation(fd('complete_grant'))).status,'error');assert.equal(calls.length,before);
assert.equal((await actions.recoverStaffInvitation(fd('cancel'))).status,'success');
assert.equal((await actions.recoverStaffInvitation(fd('reconcile'))).status,'success');
console.log('PASS recovery action mapping, gate, pause and target derivation with synthetic adapters; SQL/role/provider behavior remains unverified');
