import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
import React from 'react';
import * as jsx from 'react/jsx-runtime';
import {renderToStaticMarkup} from 'react-dom/server';

const h=React.createElement;
const box=({children,title,hint,detail,label,tone})=>h('section',{'data-tone':tone},title,label,hint,detail,children);
const action=async()=>({status:'success',message:'Synthetic'});
const id='00000000-0000-4000-8000-000000000001';
let failed=true,accountFailed=false,forms=0,role='super_admin',privilegedClients=0;
const account={user_id:id,display_name:'Synthetic operator',anonymous_pseudonym:'sample',account_status:'active',created_at:'2026-01-01T00:00:00Z',deactivated_at:null,deletion_requested_at:'2026-01-02T00:00:00Z'};
const query=()=>{
  const result=()=>({data:[],count:failed?null:0,error:failed?{message:'PRIVATE-SENTINEL'}:null});
  const chain={then:(ok,no)=>Promise.resolve(result()).then(ok,no),maybeSingle:async()=>({data:accountFailed?null:account,error:accountFailed?{message:'PRIVATE-SENTINEL'}:null})};
  for(const name of ['select','not','eq','is','order','range','limit','gte','or'])chain[name]=()=>chain;
  return chain;
};
const adapters={
  '@/lib/promotion-model':{promotionFilters:()=>{throw Error('disabled pilot');}},
  '@/components/workflows/promotion-register':{PromotionRegister:()=>{throw Error('disabled pilot');}},
  'react/jsx-runtime':jsx,'node:crypto':{randomUUID:()=>id},
  'next/link':{__esModule:true,default:({children,href})=>h('a',{href},children)},'next/navigation':{notFound:()=>{throw Error('NOT_FOUND');}},
  '@/lib/supabase/server':{createAdminClient:async()=>{privilegedClients++;return {from:query};}},
  '@/lib/governance':{
    getOperationalRole:async()=>role,getLegalRequests:async()=>({data:[],error:failed?'PRIVATE-SENTINEL':null}),
    getRecoveryDrills:async()=>({data:[],error:failed?'PRIVATE-SENTINEL':null}),
  },
  '@/components/ui/page-header':{PageHeader:box},'@/components/ui/section':{Card:box},'@/components/ui/badge':{Badge:box},
  '@/components/ui/empty-state':{EmptyState:box,ErrorPanel:box},
  '@/components/ui/operations':{CapabilityNotice:box,DataWarning:box,Pagination:box,positivePage:()=>1},
  '@/components/ui/icons':{FileLock2:()=>null,Scale:()=>null},
  '@/components/staff-attention':{RefreshAttentionOnRender:()=>null},'@/components/queue-attention-panel':{QueueAttentionPanel:()=>null},
  '@/components/workflows/workflow-form':{WorkflowForm:({children,blockUncertainRetry,action:fn,label})=>{
    assert.equal(blockUncertainRetry,true);assert.equal(typeof fn,'function');forms++;return h('form',{'aria-label':label},children);
  }},
  './actions':{createLegalRequest:action,decideLegalRequest:action,fulfilLegalRequest:action,scheduleRecoveryDrill:action,completeRecoveryDrill:action,verifyRecoveryDrill:action},
};
async function page(route){
  const exports={};const source=await readFile(new URL(`../app/(dashboard)/${route}/page.tsx`,import.meta.url),'utf8');
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText,{
    exports,Date,Promise,Boolean,process:{env:{}},require:name=>{assert(name in adapters,`Unexpected import ${name}`);return adapters[name];},
  });
  return params=>exports.default({searchParams:Promise.resolve({result:'drill_verified',...params}),params:Promise.resolve({userId:id})}).then(renderToStaticMarkup);
}
for(const route of ['privacy','privacy/requests/[userId]','approvals','recovery-readiness','legal-requests']){
  const render=await page(route);failed=true;let html=await render();
  assert(!html.includes('PRIVATE-SENTINEL'),`${route}: raw source errors never escape`);
  assert(html.includes('unknown')||html.includes('unavailable')||html.includes('incomplete'),`${route}: incomplete source visible`);
  if(route.startsWith('privacy')){assert(html.includes('unknown'));assert(!html.includes('none returned'));}
  if(route==='recovery-readiness')assert(!html.includes('No recovery drill has been registered.'));
  failed=false;html=await render();assert(!html.includes('PRIVATE-SENTINEL'));
  if(route==='privacy/requests/[userId]'){
    accountFailed=true;html=await render();assert(html.includes('Privacy request unavailable'));assert(!html.includes('PRIVATE-SENTINEL'));accountFailed=false;
  }
}
assert.equal(forms,4,'registration forms reused in both failure and healthy states');
for(const route of ['privacy','privacy/requests/[userId]']) {
  const render=await page(route);
  for(const candidate of ['super_admin','admin','moderator','support','analyst','read_only_auditor',null]) {
    role=candidate;const before=privilegedClients;
    if(['super_admin','admin'].includes(role)){await render();assert(privilegedClients>before);}
    else {await assert.rejects(render,/NOT_FOUND/);assert.equal(privilegedClients,before,'denied privacy reads never construct privileged client');}
  }
}
console.log('PASS governance server rendering: five pages, unknown versus empty sources, safe errors, guarded forms and privacy six-role gates (synthetic data, not browser evidence)');
