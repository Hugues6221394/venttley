import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
const compile=source=>ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
let invitesPaused=false;
async function load(path,dependencies={}) {
 const exports={};vm.runInNewContext(compile(await readFile(new URL(path,import.meta.url),'utf8')),{
  exports,Error,Object,URL,FormData,process:{env:{ADMIN_INVITE_REDIRECT_URL:'https://console.example.invalid',get ADMIN_STAFF_INVITES_DISABLED(){return invitesPaused?'true':'false';}}},
  require:name=>{if(!(name in dependencies))throw Error(`Unexpected import ${name}`);return dependencies[name];},
 });return exports;
}
const validate=await load('../lib/validate.ts');
const result=await load('../lib/staff-action-result.ts',{'./validate':validate});
const actor='00000000-0000-4000-8000-000000000001',target='00000000-0000-4000-8000-000000000002';
let role,session,aal,limited,stage,targetRole,superCount,lookupError,handleTaken,calls,invalidated,ledger=false;
function reset() {role='super_admin';session=true;aal='aal2';limited=false;stage='';targetRole='moderator';superCount=2;lookupError=false;handleTaken=false;calls=[];invalidated=[];ledger=false;}
const actions=await load('../app/(dashboard)/staff/actions.ts',{
 'next/cache':{revalidatePath:path=>invalidated.push(path)},
 '@/lib/staff-action-result':result,
 '@/lib/staff-invitation-ledger':{
  prepareInvitation:()=>{if(stage==='key')throw Error('invitation_key_unavailable');return ledger?{p_operation:actor}:null;},
  reserveInvitation:async()=>{assert(ledger);calls.push({name:'reserve'});if(stage==='reserve')throw Error('private ledger uncertainty');return target;},
  recordInvitation:async(id,user,progress)=>{assert(ledger);assert.equal(id,target);assert.equal(user,target);calls.push({name:progress});if(stage===progress)throw Error('private ledger progress failure');},
  completeInvitationGrant:async(operation,id,reason)=>{assert(ledger);assert.equal(operation,actor);assert.equal(id,target);assert.equal(reason,'Synthetic duty');calls.push({name:'complete_grant'});if(stage==='complete_grant')throw Error('private atomic failure');},
 },
 '@/lib/audit':{rpc:async(name,args)=>{calls.push({name,args});if(stage==='rpc')throw Error('private account secret already exists mfa required');}},
 '@/lib/guard':{limitAction:async()=>{if(limited)throw Error('Rate limit exceeded');}},
 '@/lib/staff':{activeStaffRole:async()=>role},
 '@/lib/validate':validate,
 '@/lib/supabase/server':{
  createSsrClient:async()=>({auth:{getUser:async()=>({data:{user:session?{id:actor}:null}}),mfa:{getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:aal},error:null})}}}),
  createAdminClient:async()=>({from:()=>{
   let username=false;
   const chain={select:()=>chain,eq:key=>{if(key==='username_normalized')username=true;return chain;},
    maybeSingle:async()=>({data:username?(handleTaken?{user_id:target}:null):{user_role:targetRole},error:lookupError?Error('private lookup detail'):null}),
    is:async()=>({count:superCount,error:lookupError?Error('private count detail'):null})};
   return chain;
  }}),
  createRequiredAuthAdminClient:()=>({auth:{admin:{
   inviteUserByEmail:async()=>{calls.push({name:'invite'});return stage==='invite'?{data:{user:null},error:Error('email private detail')}:{data:{user:{id:target,app_metadata:{}}},error:null};},
   updateUserById:async()=>{calls.push({name:'metadata'});return {error:stage==='metadata'?Error('private metadata failure'):null};},
  }}}),
 },
});
function data(extra={}) {
 const fd=new FormData();for(const [key,value]of Object.entries({email:'synthetic@example.invalid',pseudonym:'sample_staff',user_id:target,role:'moderator',status:'suspended',reason:'Synthetic duty',confirm:'REMOVE',...extra}))fd.set(key,value);
 return fd;
}
const names=['inviteStaff','grantExistingStaff','changeStaffRole','setStaffStatus','removeStaffAccess'];
for(const name of names) {
 for(const rejected of ['admin','moderator','support','analyst','read_only_auditor',null]) {
  reset();role=rejected;const answer=await actions[name](data());
  assert.equal(answer.status,'error');assert.equal(calls.length,0);assert.equal(invalidated.length,0);
 }
 reset();session=false;assert.equal((await actions[name](data())).status,'error');assert.equal(calls.length,0);
 reset();aal='aal1';assert((await actions[name](data())).message.includes('MFA'));assert.equal(calls.length,0);
 reset();limited=true;assert.equal((await actions[name](data())).status,'error');assert.equal(calls.length,0);
 reset();const bad=await actions[name](data({reason:''}));assert.equal(bad.status,'error');assert.equal(bad.field,'reason');assert.equal(calls.length,0);
 reset();const answer=await actions[name](data());assert.equal(answer.status,'success');
 assert(invalidated.includes('/staff/invitations')&&invalidated.includes('/staff/access-reviews'));
 assert.equal(calls.filter(call=>call.name.startsWith('admin_')).length,1);
 reset();stage='rpc';const ambiguous=await actions[name](data());
 assert.equal(ambiguous.status,'unknown');assert(!JSON.stringify(ambiguous).includes('private'));
 assert.equal(calls.filter(call=>call.name.startsWith('admin_')).length,1,'no automatic retry');
 assert.equal(invalidated.length,0,'failed/ambiguous response does not trigger form-clearing revalidation');
}
for(const name of names.filter(name=>name!=='inviteStaff')) {
 reset();const answer=await actions[name](data({user_id:actor}));assert.equal(answer.status,'error');assert(answer.message.includes('Self-changes'));assert.equal(calls.length,0);
}
for(const name of ['changeStaffRole','removeStaffAccess']) {
 reset();targetRole='super_admin';superCount=1;
 const answer=await actions[name](data());assert.equal(answer.status,'error');assert(answer.message.includes('last active'));assert.equal(calls.length,0);
}
reset();assert.equal((await actions.removeStaffAccess(data({confirm:'remove'}))).field,'confirm');assert.equal(calls.length,0);
reset();assert.equal((await actions.inviteStaff(data({role:'super_admin'}))).field,'role');assert.equal(calls.length,0);
reset();assert.equal((await actions.grantExistingStaff(data({user_id:'bad'}))).field,'user_id');assert.equal(calls.length,0);
reset();handleTaken=true;assert.equal((await actions.inviteStaff(data())).field,'pseudonym');assert.equal(calls.length,0);
for(const failure of ['invite','metadata']) {
 reset();stage=failure;const answer=await actions.inviteStaff(data());assert.equal(answer.status,'unknown');
 assert.equal(calls.filter(call=>call.name==='invite').length,1);assert.equal(invalidated.length,0);
}
assert(!result.staffSuccess('invited').message.includes('Invitation sent'));
// Prepared enabled-ledger branches: no provider call without a confirmed first
// reservation; any later failure retains the attempt and suppresses auto-retry.
reset();ledger=true;assert.equal((await actions.inviteStaff(data())).status,'success');
assert.deepEqual(calls.map(call=>call.name),['reserve','invite','provider_accepted','metadata','complete_grant']);
for(const tracked of [false,true]) {
 reset();ledger=tracked;invitesPaused=true;
 assert.equal((await actions.inviteStaff(data())).status,'error');assert.equal(calls.length,0,'emergency pause stops legacy and tracked writes');
}
invitesPaused=false;
for(const failure of ['key','reserve','provider_accepted','complete_grant']) {
 reset();ledger=true;stage=failure;const answer=await actions.inviteStaff(data());
 assert.equal(answer.status,failure==='key'?'error':'unknown');assert.equal(invalidated.length,0);
 assert.equal(calls.filter(call=>call.name==='invite').length,['key','reserve'].includes(failure)?0:1);
 if(failure==='provider_accepted')assert(!calls.some(call=>call.name==='admin_set_user_role'));
 assert(!JSON.stringify(answer).includes('private ledger'));
}
assert.equal(result.staffFailure(new validate.InvalidInput('unexpected','private'),false).field,undefined);
const source=await readFile(new URL('../components/workflows/workflow-form.tsx',import.meta.url),'utf8');
assert(source.includes("blockUncertainRetry&&result?.status==='unknown'"));
assert(source.includes("result?.status==='success'||uncertainLocked)return"));
assert(source.includes('disabled={!ready||disabled||pending||uncertainLocked}'));
assert(source.includes('method="post"'),'never allow pre-hydration default GET submission of sensitive inputs');
assert(!source.includes('localStorage')||source.includes('not localStorage'));
const actionSource=await readFile(new URL('../app/(dashboard)/staff/actions.ts',import.meta.url),'utf8');
assert(!actionSource.includes('redirect('),'action failures must return in place, not discard inputs via redirect');
console.log('PASS staff actions: five runtime authorization/MFA/rate gates, validation, self/last-admin guards, success, partial invitation and ambiguous-write handling with synthetic adapters');
