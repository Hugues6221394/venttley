// Prepared for the deferred verification pass. No network or real accounts.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import * as crypto from 'node:crypto';
import ts from 'typescript';
let enabled=false,key='ab'.repeat(32),calls=[],dispatch=true;
async function load(path,dependencies={}) {
 const exports={};vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
  exports,Error,Buffer,Date,Number,Object,Array,URLSearchParams,FormData,
  process:{env:{get ADMIN_INVITATION_LEDGER_UI(){return enabled?'true':'false';},get ADMIN_INVITATION_HMAC_KEY(){return key;}}},
  require:name=>{assert(name in dependencies,`Unexpected dependency ${name}`);return dependencies[name];},
 });return exports;
}
const id='1a790000-0000-4000-8000-000000000001';
const model=await load('../lib/staff-invitation-model.ts');
assert.equal(model.invitationCursor({}).beforeAt,null);
assert.equal(model.parseInvitationRegister(null),null);
assert.equal(model.parseInvitationRegister({enabled:false}).enabled,false);
assert.equal(model.parseInvitationRegister({enabled:true,measured_at:'bad',items:[]}),null);
assert.equal(model.parseInvitationRegister({enabled:true,measured_at:'2026-09-30T10:00:00Z',items:[{}]}),null);
assert.equal(model.parseInvitationRegister({enabled:true,measured_at:'2026-09-30T10:00:00Z',items:[]}).items.length,0);
for(const bad of [{beforeAt:'2026-09-30T10:00:00Z'},{beforeId:id},{beforeId:[id],beforeAt:'2026-09-30T10:00:00Z'},{beforeId:id,beforeAt:['2026-09-30T10:00:00Z']},{beforeId:'bad',beforeAt:'2026-09-30T10:00:00Z'},{beforeId:id,beforeAt:'infinity'}])assert.equal(model.invitationCursor(bad),null);
const timestamp='2026-09-30T10:00:00.123456+00:00';
assert.equal(model.invitationCursor({beforeAt:timestamp,beforeId:id}).beforeAt,timestamp);
assert.equal(new URL(model.invitationHref({created_at:timestamp,invitation_id:id}),'https://synthetic.invalid').searchParams.get('beforeAt'),timestamp);
const validate=await load('../lib/validate.ts');
const helpers=await load('../lib/staff-invitation-ledger.ts',{
 'server-only':{},'node:crypto':crypto,'./validate':validate,'./staff':{},'./supabase/server':{},
 './staff-invitation-model':model,
 './audit':{rpc:async(name,params)=>{calls.push({name,params});return {invitation_id:id,dispatch_allowed:dispatch};}},
});
const fd=new FormData();fd.set('operation_id',id);
assert.equal(helpers.prepareInvitation(fd,'example@example.invalid','sample_staff','moderator'),null);
enabled=true;
const first=helpers.prepareInvitation(fd,' Example@Example.invalid ','sample_staff','moderator');
assert.equal(first.p_mailbox_hmac,helpers.prepareInvitation(fd,'example@example.invalid','sample_staff','moderator').p_mailbox_hmac);
assert.equal(first.p_mailbox_hmac.length,64);assert(!JSON.stringify(first).includes('@'));
assert.notEqual(first.p_mailbox_hmac,crypto.createHash('sha256').update('example@example.invalid').digest('hex'));
key='short';assert.throws(()=>helpers.prepareInvitation(fd,'example@example.invalid','sample_staff','moderator'),/invitation_key_unavailable/);
key='ab'.repeat(32);
assert.equal(await helpers.reserveInvitation(first),id);assert.equal(calls.length,1);
dispatch=false;await assert.rejects(helpers.reserveInvitation(first),/invitation_already_attempted/);assert.equal(calls.length,2,'no implicit RPC retry');
await helpers.recordInvitation(id,id,'provider_accepted');assert.equal(calls.at(-1).name,'admin_record_staff_invitation');
await helpers.completeInvitationGrant(id,id,'Synthetic duty');assert.equal(calls.at(-1).name,'admin_recover_staff_invitation');
assert.equal(calls.at(-1).params.p_version,2);assert.equal(calls.at(-1).params.p_reason,'Synthetic duty');
console.log('PASS invitation model/HMAC and reservation replay contract with synthetic adapters; no live Auth/database proof');
