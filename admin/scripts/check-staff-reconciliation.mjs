import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import ts from 'typescript';
import {createClient} from '@supabase/supabase-js';
const source=await readFile(new URL('../lib/bounded.ts',import.meta.url),'utf8');
const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {reconcileBounded,fetchWithDeadline}=await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
let active=0,peak=0;
const values=await reconcileBounded([1,2,3,4,5],2,1000,async value=>{
 active++;peak=Math.max(peak,active);await new Promise(r=>setTimeout(r,2));active--;
 if(value===3)throw Error('private provider detail');
 return value*2;
});
assert.equal(peak,2);
assert.deepEqual(values,[{status:'fulfilled',value:2},{status:'fulfilled',value:4},{status:'unavailable'},{status:'fulfilled',value:8},{status:'fulfilled',value:10}]);
assert(!JSON.stringify(values).includes('private provider'));
let started=0,cancelled=0;
const partial=await reconcileBounded([1,2,3,4,5],2,30,async(value,signal)=>{
 started++;
 if(value===1)return 'kept';
 return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>{cancelled++;reject(Error('cancelled'));},{once:true}));
});
assert.equal(started,3,'queued lookups do not start after shared deadline');
assert.equal(cancelled,2,'in-flight transports receive cancellation');
assert.deepEqual(partial[0],{status:'fulfilled',value:'kept'});
assert(partial.slice(1).every(row=>row.status==='unavailable'));
const frozen=JSON.stringify(partial);await new Promise(r=>setTimeout(r,10));assert.equal(JSON.stringify(partial),frozen);
let finishLate;
const late=await reconcileBounded([1],1,10,()=>new Promise(resolve=>{finishLate=resolve;}));
finishLate('late private value');await new Promise(r=>setTimeout(r,0));
assert.deepEqual(late,[{status:'unavailable'}],'late completion never changes returned snapshot');
assert.deepEqual(await reconcileBounded([],2,10,()=>{throw Error('not called');}),[]);
for(const [threads,budget] of [[0,10],[1,0],[1.5,10],[1,NaN]])await assert.rejects(reconcileBounded([1],threads,budget,async()=>1));
const batch=new AbortController(),caller=new AbortController();let observed;
await fetchWithDeadline(batch.signal,async(input,init)=>{observed=init.signal;return new Response('{}');})('https://synthetic.invalid',{signal:caller.signal});
caller.abort();assert(observed.aborted,'caller cancellation retained');
let requestSignal;
const requestController=new AbortController();
await fetchWithDeadline(batch.signal,async(input,init)=>{requestSignal=init.signal;return new Response('{}');})(new Request('https://synthetic.invalid',{signal:requestController.signal}));
batch.abort();assert(requestSignal.aborted,'batch cancellation reaches Request input');
const transportFailure=await fetchWithDeadline(new AbortController().signal,async()=>{throw Error('private URL and account detail');})('https://synthetic.invalid');
assert.equal(transportFailure.status,503);
assert.equal(transportFailure.headers.get('Cache-Control'),'no-store');
assert.equal(await transportFailure.text(),'{"message":"Staff lookup unavailable"}');
// Execute the installed Auth SDK through the same custom-fetch boundary. No
// real account/key/network is used; this tests transport cancellation, not RLS.
const users=['00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002'];
let client,aborts=0,sdk;
const originalError=console.error, sdkLogs=[];
console.error=(...args)=>sdkLogs.push(args);
try {
sdk=await reconcileBounded(users,2,30,async(id,signal)=>{
 client??=createClient('https://synthetic.invalid','synthetic-key',{
  auth:{persistSession:false,autoRefreshToken:false},
  global:{fetch:fetchWithDeadline(signal,async(input,init)=>{
   if(String(input).endsWith(users[0]))return new Response(JSON.stringify({id:users[0],aud:'authenticated',role:'authenticated',email:'synthetic@example.invalid'}),{headers:{'Content-Type':'application/json'}});
   return new Promise((resolve,reject)=>init.signal.addEventListener('abort',()=>{aborts++;reject(new DOMException('Read cancelled','AbortError'));},{once:true}));
  })},
 });
 const result=await client.auth.admin.getUserById(id);if(result.error)throw result.error;return result.data.user.id;
});
// Allow the SDK's cancellation continuation to finish before checking logs.
await new Promise(resolve=>setTimeout(resolve,0));
} finally { console.error=originalError; }
assert.equal(sdk[0].status,'fulfilled');assert.equal(sdk[1].status,'unavailable');assert.equal(aborts,1);
assert.deepEqual(sdkLogs,[],'SDK never logs raw transport errors');
// Source contracts complement the runtime transport tests; they are not a
// substitute for browser tests with actual role/session changes.
for(const route of ['staff','staff/invitations','staff/access-reviews']) {
 const page=await readFile(new URL(`../app/(dashboard)/${route}/page.tsx`,import.meta.url),'utf8');
 assert(page.includes('activeStaffRole(ssr, actor.id, ["super_admin"])'),`${route} retains independent active-role authorization`);
 assert(page.includes('reconcileBounded(') && page.includes('createRequiredAuthAdminClient(signal)'),`${route} wires the transport deadline`);
 assert(!page.includes('mapBounded('),`${route} must preserve partial successes`);
}
const invitations=await readFile(new URL('../app/(dashboard)/staff/invitations/page.tsx',import.meta.url),'utf8');
assert(invitations.includes('const complete = errors.length === 0;'));
assert(invitations.includes('this page of inspected staff, not all invitations'),'bounded page metrics never claim global totals');
for(const counter of ['pending','unconfirmed','acceptedNotCompleted'])assert(invitations.includes(`value={complete ? ${counter} : null}`),'incomplete invitation totals are unknown');
const reviews=await readFile(new URL('../app/(dashboard)/staff/access-reviews/page.tsx',import.meta.url),'utf8');
assert(reviews.includes('if (!auth) reasons.push("Auth posture unknown")'),'unresolved staff remain review candidates');
console.log('PASS staff reconciliation: bounded concurrency/deadline, partial results, safe failures, late completion, cancellation and installed Auth SDK transport');
