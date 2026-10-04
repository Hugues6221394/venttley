// Execute real action/guard modules with synthetic adapters; no Auth or SQL writes.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
import React from 'react';
import * as jsx from 'react/jsx-runtime';
import {renderToStaticMarkup} from 'react-dom/server';
let ledger=true,enabled=true,paused=false,role='super_admin',active=true,session=true,aal='aal2',limited=false,failure=null,calls=[];
const env={get ADMIN_INVITATION_LEDGER_UI(){return String(ledger);},get ADMIN_INVITATION_SETUP_REPAIR_UI(){return String(enabled);},get ADMIN_STAFF_INVITES_DISABLED(){return String(paused);}};
async function load(path,deps={}) {
  const exports={};
  vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true},
  }).outputText,{exports,Error,FormData,URLSearchParams,Date,process:{env},require:name=>{assert(name in deps,`Unexpected dependency ${name}`);return deps[name];}});
  return exports;
}
const validate=await load('../lib/validate.ts');
const model=await load('../lib/workflow-model.ts',{'./inbox-model':{isUuid:()=>true}});
const server={createSsrClient:async()=>({auth:{getUser:async()=>({data:{user:session?{id:'synthetic'}:null}}),
  mfa:{getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:aal},error:null})}}})};
const actor=await load('../lib/operational-actions.ts',{'server-only':{},'@/lib/supabase/server':server,
  '@/lib/staff':{activeStaffRole:async(_db,_id,roles)=>active&&roles.includes(role)?role:null},
  '@/lib/guard':{limitAction:async()=>{if(limited)throw Error('rate_limited');}},
});
const governance=await load('../lib/governance-action.ts',{'server-only':{},'./validate':validate,'./workflow-model':model,
  './supabase/server':server,'./operational-actions':actor,'./audit':{rpc:async(fn,params)=>{calls.push({fn,params});if(failure)throw Error(failure.replace('{fn}',fn));}},
});
const actions=await load('../lib/staff-invitation-actions.ts',{'./governance-action':governance,'./validate':validate});
const id='1a795000-0000-4000-8000-000000000001';
function form(extra={}){const fd=new FormData();for(const [key,value]of Object.entries({operation_id:id,invitation_id:id,version:'2',...extra}))fd.set(key,value);return fd;}
function reset(){ledger=true;enabled=true;paused=false;role='super_admin';active=true;session=true;aal='aal2';limited=false;failure=null;calls=[];}
for(const candidate of ['super_admin','admin','moderator','support','analyst','read_only_auditor']){
  reset();role=candidate;const result=await actions.repairStaffInvitationSetup(form({user_id:'forged-target',role:'super_admin'}));
  assert.equal(result.status,candidate==='super_admin'?'success':'error');assert.equal(calls.length,candidate==='super_admin'?1:0);
  if(calls.length){assert.equal(calls[0].fn,'admin_repair_staff_invitation_setup');assert.deepEqual(Object.keys(calls[0].params).sort(),['p_invitation','p_operation','p_version']);assert.equal(calls[0].params.p_version,2);assert(result.message.includes('No password changed'));}
}
for(const state of ['ledger-off','repair-off','paused','missing','inactive','aal1','rate']){
  reset();if(state==='ledger-off')ledger=false;if(state==='repair-off')enabled=false;if(state==='paused')paused=true;
  if(state==='missing')session=false;if(state==='inactive')active=false;if(state==='aal1')aal='aal1';if(state==='rate')limited=true;
  assert.equal((await actions.repairStaffInvitationSetup(form())).status,'error');assert.equal(calls.length,0);
}
for(const extra of [{invitation_id:'bad'},{operation_id:'bad'},{version:'0'},{version:''},{version:'1e2'}]){
  reset();assert.equal((await actions.repairStaffInvitationSetup(form(extra))).status,'error');assert.equal(calls.length,0);
}
for(const code of ['not_authorized','aal2_required','rate_limited','idempotency_payload_mismatch','invitation_conflict','invitation_setup_repair_disabled','invitation_setup_ineligible','invitation_session_unavailable','invitation_grant_closed','invitation_binding_mismatch','invitation_evidence_missing']){
  reset();failure=`{fn}: ${code}`;assert.equal((await actions.repairStaffInvitationSetup(form())).status,'error');assert.equal(calls.length,1);
}
for(const message of ['timeout PRIVATE-SENTINEL','{fn}: unexpected invitation_setup_ineligible PRIVATE-SENTINEL']){
  reset();failure=message;const result=await actions.repairStaffInvitationSetup(form());assert.equal(result.status,'unknown');assert(!JSON.stringify(result).includes('PRIVATE-SENTINEL'));assert.equal(calls.length,1,'no automatic RPC retry');
}

// Render the actual register with safe fictional records and a form adapter.
reset();let forms=[];
const record={invitation_id:id,username:'synthetic_staff',requested_role:'support',state:'provider_accepted',created_at:'2026-10-01T10:00:00Z',provider_accepted_at:'2026-10-01T10:00:00Z',access_assigned_at:null,requested_by_name:'Synthetic Operator',current_role:'normal',account_status:'active',sign_in_observed:false,auth_record_missing:false,version:2,grant_expires_at:'2026-10-02T10:00:00Z',cancelled_at:null,grant_expired:false,setup_ready:false};
let item={...record};const h=React.createElement,box=({children,title,label,detail})=>h('section',{},title,label,detail,children);
const invitationModel=await load('../lib/staff-invitation-model.ts');
const register=await load('../components/workflows/staff-invitation-register.tsx',{
 'react/jsx-runtime':jsx,'node:crypto':{randomUUID:()=>id},'next/link':{__esModule:true,default:({href,children})=>h('a',{href},children)},
 '@/lib/staff-invitation-actions':actions,'@/lib/staff-invitation-model':invitationModel,
 '@/lib/staff-invitation-ledger':{readInvitationRegister:async()=>({enabled:true,measured_at:record.created_at,items:[item]})},
 './workflow-form':{WorkflowForm:props=>{forms.push(props);return h('form',{},props.label,props.children);}},
 '@/components/ui/page-header':{PageHeader:box},'@/components/ui/section':{Card:box},'@/components/ui/badge':{Badge:box},
 '@/components/ui/empty-state':{ErrorPanel:box},'@/components/ui/operations':{CapabilityNotice:box,DataWarning:box},
});
async function render(){forms=[];return renderToStaticMarkup(await register.StaffInvitationRegister({cursor:{beforeAt:null,beforeId:null}}));}
assert((await render()).includes('Check and repair missing setup'));
const repairForm=forms.find(f=>f.action===actions.repairStaffInvitationSetup);assert(repairForm.blockUncertainRetry);assert(repairForm.confirmation.includes('does not send mail'));
for(const change of [{cancelled_at:record.created_at},{grant_expired:true},{setup_ready:true},{current_role:'moderator'},{account_status:'suspended'},{sign_in_observed:true},{auth_record_missing:true},{state:'reserved'}]){
  item={...record,...change};assert(!(await render()).includes('Check and repair missing setup'));
}
item={...record};enabled=false;assert(!(await render()).includes('Check and repair missing setup'));
enabled=true;paused=true;await render();assert(forms.find(f=>f.action===actions.repairStaffInvitationSetup).disabled);
console.log('PASS invitation setup action: six roles, MFA/session/pause/rate gates, safe errors, server-derived target and guarded register rendering (synthetic; no live Auth/SQL proof)');
