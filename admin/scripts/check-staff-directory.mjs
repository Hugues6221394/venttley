import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import ts from 'typescript';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {createClient} from '@supabase/supabase-js';

const require=createRequire(import.meta.url);
const compile=source=>ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText;
async function load(path,overrides={}) {
 const exports={};
 vm.runInNewContext(compile(await readFile(new URL(path,import.meta.url),'utf8')),{
  exports,require:name=>name in overrides?overrides[name]:require(name),URLSearchParams,AbortSignal,
  process:{env:{ADMIN_INVITE_REDIRECT_URL:'https://synthetic.invalid'}},console,
 },{filename:path});
 return exports;
}
const model=await load('../lib/staff-directory-model.ts');
const {directoryFilters,directoryHref,staffDirectoryQuery,activeSuperAdminQuery,STAFF_PAGE_SIZE}=model;
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
assert.equal(STAFF_PAGE_SIZE,25);
assert.equal(directoryFilters({}).role,'all');
for(const input of [{role:['admin']},{role:'normal'},{role:'admin),user_role.eq.normal'},{status:['active']},{status:'disabled'},{after:''},{after:['x']},{after:'x'.repeat(10000)},{after:`${id(1)},user_role.eq.normal`}])assert.equal(directoryFilters(input),null);
const parsed=directoryFilters({role:'moderator',status:'inactive',after:id(25)});
assert(parsed);
assert.equal(directoryHref(parsed),'/staff?role=moderator&status=inactive');
assert.equal(new URL(directoryHref(parsed,id(50)),'https://synthetic.invalid').searchParams.get('after'),id(50));

// Actual installed PostgREST SDK builds the requests. Transport is synthetic,
// not a database emulator or proof of grants/query plans.
let requests=[],dbFailed=false,protectionFailed=false,returnedRows=[];
const db=createClient('https://synthetic.invalid','synthetic-key',{
 auth:{persistSession:false,autoRefreshToken:false},
 global:{fetch:async(input,init)=>{
  assert(init.signal instanceof AbortSignal,'each database read has a cancellation boundary');
  const url=new URL(input);requests.push(url);
  const isProtection=url.searchParams.get('select')==='user_id';
  const failed=isProtection?protectionFailed:dbFailed;
  return new Response(JSON.stringify(failed?{message:'sensitive database sentinel'}:isProtection?[{user_id:id(100)},{user_id:id(101)}]:returnedRows),{
   status:failed?400:200,headers:{'Content-Type':'application/json'},
  });
 }},
});
await staffDirectoryQuery(db,parsed);
let query=requests.at(-1).searchParams;
assert.equal(query.get('limit'),'26');assert.equal(query.get('offset'),null);
assert.equal(query.get('order'),'user_id.asc');
assert(query.getAll('user_role').some(value=>value.startsWith('in.(')));
assert(query.getAll('user_role').includes('eq.moderator'));
assert.equal(query.get('user_id'),`gt.${id(25)}`);
assert.equal(query.get('or'),'(account_status.neq.active,deactivated_at.not.is.null)');
await staffDirectoryQuery(db,directoryFilters({status:'active'}));
query=requests.at(-1).searchParams;
assert.equal(query.get('account_status'),'eq.active');assert.equal(query.get('deactivated_at'),'is.null');
await activeSuperAdminQuery(db);
query=requests.at(-1).searchParams;
assert.equal(query.get('limit'),'2');assert.equal(query.get('user_role'),'eq.super_admin');
assert.equal(query.get('account_status'),'eq.active');assert.equal(query.get('deactivated_at'),'is.null');
assert.equal(query.get('user_id'),null,'protection check is never scoped to current cursor');
let abortObserved=false;
const waitingDb=createClient('https://synthetic.invalid','synthetic-key',{
 auth:{persistSession:false,autoRefreshToken:false},
 global:{fetch:async(input,init)=>new Promise((resolve,reject)=>{
  const cancel=()=>{abortObserved=true;reject(new DOMException('Cancelled synthetic read','AbortError'));};
  if(init.signal.aborted)cancel();else init.signal.addEventListener('abort',cancel,{once:true});
 })},
});
const deadline=new AbortController(),timer=setTimeout(()=>deadline.abort(),10);
const aborted=await staffDirectoryQuery(waitingDb,directoryFilters({}),deadline.signal);
clearTimeout(timer);assert(abortObserved);assert(aborted.error);assert.equal(aborted.data,null);

// Execute the real async page with synthetic authorization and data adapters.
// Render it server-side to check failure/empty states and navigation semantics.
let actorRole='super_admin',sessionPresent=true,active=true,adminCalls=0,authLookups=[],authFailure=false;
const action=async()=>{};
const box=({children,title,hint,detail})=>React.createElement('section',null,title,hint,detail,children);
const link={__esModule:true,default:({children,href,...props})=>React.createElement('a',{href,'aria-label':props['aria-label']},children)};
const controls=await load('../components/staff-directory-controls.tsx',{'next/link':link,'@/lib/staff-directory-model':model});
const adapters={
 '@/lib/staff-invitation-model':{invitationCursor:()=>{throw Error('disabled invitation pilot must retain existing filters');}},
 '@/components/workflows/staff-invitation-register':{StaffInvitationRegister:()=>{throw Error('disabled invitation pilot must retain existing page');}},
 '@/lib/access-review-model':{reviewFilters:()=>{throw Error('disabled pilot must not parse canonical filters');}},
 '@/components/workflows/access-review-register':{AccessReviewRegister:()=>{throw Error('disabled pilot must retain existing page');}},
 'next/link':link,
 'next/navigation':{notFound:()=>{throw Error('NOT_FOUND');}},
 '@/lib/staff':{activeStaffRole:async()=>active?actorRole:null},
 '@/lib/staff-directory-model':model,
 '@/components/staff-directory-controls':controls,
 '@/components/workflows/workflow-form':{WorkflowForm:({children,label,disabled,blockUncertainRetry})=>{
  assert.equal(blockUncertainRetry,true,'staff forms must lock ambiguous retries');
  return React.createElement('form',{'aria-label':label},React.createElement('fieldset',{disabled},children));
 }},
 '@/lib/bounded':{reconcileBounded:async(items,concurrency,budget,worker)=>{
  assert(items.length<=25,'Auth never fetches more than one visible page');
  assert.equal(concurrency,5);assert.equal(budget,6000);
  return Promise.all(items.map(async item=>({status:'fulfilled',value:await worker(item,new AbortController().signal)})));
 }},
 '@/lib/supabase/server':{
  createSsrClient:async()=>({auth:{getUser:async()=>({data:{user:sessionPresent?{id:id(999)}:null}})}}),
  createAdminClient:async()=>{adminCalls++;return db;},
  createRequiredAuthAdminClient:()=>({auth:{admin:{getUserById:async userId=>{
   authLookups.push(userId);return authFailure?{data:{user:null},error:Error('sensitive provider sentinel')}:{data:{user:{id:userId,email:'synthetic@example.invalid',email_confirmed_at:'2026-09-28T00:00:00Z',last_sign_in_at:new Date().toISOString(),app_metadata:{}}},error:null};
  }}}}),
 },
 '@/components/ui/page-header':{PageHeader:box},
 '@/components/ui/section':{Card:box},
 '@/components/ui/badge':{Badge:box},
 '@/components/ui/empty-state':{EmptyState:box,ErrorPanel:box},
 '@/components/ui/operations':{CapabilityNotice:box,DataWarning:box},
 '@/components/ui/icons':{KeyRound:()=>null,UserRoundCog:()=>null,ClipboardCheck:()=>null},
 './actions':{changeStaffRole:action,grantExistingStaff:action,inviteStaff:action,removeStaffAccess:action,setStaffStatus:action},
};
const page=await load('../app/(dashboard)/staff/page.tsx',adapters);
const render=async(params={})=>renderToStaticMarkup(await page.default({searchParams:Promise.resolve(params)}));
for(const role of ['admin','moderator','support','analyst','read_only_auditor','normal']) {
 actorRole=role;await assert.rejects(render(),/NOT_FOUND/);
}
actorRole='super_admin';active=false;await assert.rejects(render(),/NOT_FOUND/);
active=true;sessionPresent=false;await assert.rejects(render(),/NOT_FOUND/);sessionPresent=true;
assert.equal(adminCalls,0,'unauthorized actors never reach service-role data');
let html=await render({role:['admin']});
assert(html.includes('Invalid staff filters'));assert.equal(adminCalls,0);
returnedRows=Array.from({length:26},(_,i)=>({user_id:id(i+1),display_name:`Synthetic ${i+1}`,anonymous_pseudonym:`staff_${i+1}`,user_role:'moderator',account_status:'active',deactivated_at:null}));
authLookups=[];html=await render({role:'moderator',status:'active'});
assert.equal(authLookups.length,25);assert(!authLookups.includes(id(26)));
assert(html.includes('25 accounts on this page'));assert(html.includes('2+ active super admins across the directory'));
assert(html.includes('role=moderator&amp;status=active&amp;after='+id(25)));
assert(!html.includes('Synthetic 26'));
returnedRows=[{...returnedRows[0],user_role:'super_admin'}];protectionFailed=true;
html=await render({after:id(10)});
assert(html.includes('Super-admin safety count is unavailable'));
assert(html.includes('disabled=""'));assert(html.includes('First page'));assert(!html.includes('Next page'));
assert(!html.includes('sensitive database sentinel'));
dbFailed=true;html=await render();
assert(html.includes('Staff directory could not be loaded'));
assert(!html.includes('No staff accounts on this page'));
assert(!html.includes('0 accounts on this page'));assert(!html.includes('sensitive database sentinel'));
dbFailed=false;protectionFailed=false;returnedRows=[];
html=await render({role:'analyst'});assert(html.includes('No staff accounts on this page'));
for(const route of ['invitations','access-reviews']) {
 const child=await load(`../app/(dashboard)/staff/${route}/page.tsx`,adapters);
 const renderChild=async(params={})=>renderToStaticMarkup(await child.default({searchParams:Promise.resolve(params)}));
 const before=adminCalls;
 for(const role of ['admin','moderator','support','analyst','read_only_auditor','normal']) {
  actorRole=role;await assert.rejects(renderChild(),/NOT_FOUND/);
 }
 actorRole='super_admin';active=false;await assert.rejects(renderChild(),/NOT_FOUND/);active=true;
 sessionPresent=false;await assert.rejects(renderChild(),/NOT_FOUND/);sessionPresent=true;
 assert.equal(adminCalls,before,`${route}: denied actors never reach service-role reads`);
 html=await renderChild({after:'hostile'});assert(html.includes('Invalid staff filters'));assert.equal(adminCalls,before);
 returnedRows=Array.from({length:26},(_,i)=>({user_id:id(i+1),display_name:`Synthetic ${i+1}`,anonymous_pseudonym:`staff_${i+1}`,user_role:'moderator',account_status:'active',deactivated_at:null}));
 authLookups=[];html=await renderChild({role:'moderator'});
 assert.equal(authLookups.length,25);assert(!authLookups.includes(id(26)));
 assert(html.includes(`/staff/${route}?role=moderator&amp;status=all&amp;after=${id(25)}`),'next page remains reachable even with no findings');
 assert(html.includes('No '+(route==='invitations'?'incomplete invitations derived':'review candidates were derived')+' on this page'));
 assert(html.includes('this page of inspected staff'));assert(!html.includes('Synthetic 26'));
 authFailure=true;html=await renderChild();
 assert(html.includes('unknown'));assert(!html.includes('sensitive provider sentinel'));
 if(route==='access-reviews')assert(html.includes('Auth posture unknown')&&html.includes('Synthetic 1'));
 authFailure=false;dbFailed=true;authLookups=[];html=await renderChild();
 assert.equal(authLookups.length,0);assert(html.includes('Staff records could not be loaded'));
 assert(html.includes('unknown'));assert(!html.includes('sensitive database sentinel'));
 dbFailed=false;
}
console.log('PASS staff pages: SDK query bounds, cursor/filter validation, global protection, three real page authorization/failure/navigation journeys with synthetic adapters');
