// Prepared for the deferred test pass. No live database or network.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
let enabled=false,calls=[];
async function load(path,dependencies={}){
 const exports={};vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
  exports,Error,Date,Number,Object,Array,URLSearchParams,FormData,process:{env:{get ADMIN_ACCESS_REVIEWS_UI(){return enabled?'true':'false';}}},
  require:name=>{assert(name in dependencies,`Unexpected dependency ${name}`);return dependencies[name];},
 });return exports;
}
const id='1a780000-0000-4000-8000-000000000003';
const model=await load('../lib/access-review-model.ts',{'./inbox-model':{isUuid:v=>typeof v==='string'&&/^[0-9a-f-]{36}$/i.test(v)}});
assert.equal(model.reviewFilters({}).campaign,null);
for(const invalid of [{campaign:['x']},{campaign:'bad'},{after:id},{before:'2026-00-01'},{before:'2026-02-30'},{before:''},{campaign:id,before:'2026-01-01'}])assert.equal(model.reviewFilters(invalid),null);
assert.equal(model.reviewFilters({campaign:id,after:id}).after,id);
assert.equal(model.reviewHref({campaign:id}),`/staff/access-reviews?campaign=${id}`);
const validate=await load('../lib/validate.ts');
const actions=await load('../lib/access-review-actions.ts',{
 './validate':validate,'./governance-action':{
  governanceInteger:(fd,key,min,max)=>validate.intInRange(fd,key,min,max),
  governanceUtcTime:(fd,key)=>`${fd.get(key)}:00.000Z`,
  governanceAction:async(roles,fn,parameters,message)=>{assert.deepEqual(Array.from(roles),['super_admin']);calls.push({fn,params:parameters()});return {status:'success',message};},
 },
});
function fd(extra={}){const form=new FormData();for(const [k,v]of Object.entries({operation_id:id,campaign_id:id,subject_id:id,reviewer_id:id,version:'1',period:'2026-09',due_at:'2026-10-01T12:00',valid_until:'2026-10-30T12:00',command:'retain',reason_code:'inactive_access',...extra}))form.set(k,v);return form;}
assert.equal((await actions.createAccessReview(fd())).status,'error');assert.equal((await actions.commandAccessReview(fd())).status,'error');assert.equal(calls.length,0,'disabled pilot never reaches mutation helper');
enabled=true;await actions.createAccessReview(fd());assert.equal(calls.at(-1).params.p_period,'2026-09-01');
await assert.rejects(actions.createAccessReview(fd({period:'hostile'})),/period/);
for(const command of ['retain','require_revocation','confirm_revoked','refresh','reassign','close']){
 await actions.commandAccessReview(fd({command}));const p=calls.at(-1).params;
 assert.equal(p.p_operation,id);assert.equal(p.p_command,command);
 assert.equal(p.p_subject,command==='close'?null:id);
 assert.equal(p.p_reviewer,command==='reassign'?id:null);
 assert.equal(p.p_valid_until,command==='retain'?'2026-10-30T12:00:00.000Z':null);
}
await assert.rejects(actions.commandAccessReview(fd({command:'delete'})),/command/);
await assert.rejects(actions.commandAccessReview(fd({campaign_id:'hostile'})),/campaign_id/);
const sql=await readFile(new URL('../../supabase/pending/access_review_ledger.sql',import.meta.url),'utf8');
assert(sql.includes('DEFAULT false'));assert(sql.includes('private.admin_operation_existing'));
assert(sql.includes('FOR UPDATE'));assert(sql.includes('i.version<>p_version'));
assert(!sql.includes('UPDATE public.users'),'review records never pretend to perform staff revocation');
console.log('PASS access-review model and action mapping with synthetic adapters; SQL assertions are source contracts, not database execution');
