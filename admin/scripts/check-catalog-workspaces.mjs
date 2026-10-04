// Prepared synthetic checks. No live database, browser or service dependency.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import {dashboardRoutes,resolveSmokeRoute} from './route-inventory.mjs';
const exports={};
vm.runInNewContext(ts.transpileModule(await readFile(new URL('../lib/catalog-workspace-model.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
 exports,URLSearchParams,require:name=>{assert.equal(name,'./inbox-model');return {isUuid:v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)};},
});
const id='2b792000-0000-4000-8000-000000000001';
for(const params of [{after:'bad'},{q:['a']},{kind:'message'},{state:'secret'},{q:'x'.repeat(81)},{q:'a\nb'}])assert.equal(exports.catalogFilters('tribes',params),null);
assert.equal(exports.catalogFilters('media',{}).state,'pending');
assert.equal(exports.catalogFilters('media',{state:'pending',kind:'whisper'}).kind,'whisper');
assert.equal(exports.catalogFilters('tribes',{q:'  Calm  '}).q,'Calm');
const filters=exports.catalogFilters('tribes',{q:'Calm',state:'featured',after:id});
const next=new URL(exports.catalogHref('tribes',filters,id),'http://localhost');
assert.equal(next.searchParams.get('q'),'Calm');assert.equal(next.searchParams.get('state'),'featured');assert.equal(next.searchParams.get('after'),id);
assert.equal(exports.literalPrefix('a%_\\*'),'a\\%\\_\\\\\\*%');
const routes=dashboardRoutes(fileURLToPath(new URL('../app/(dashboard)',import.meta.url)));
assert(routes.includes('/privacy/requests/[userId]'));assert(routes.includes('/incidents/records/[id]'));assert.equal(new Set(routes).size,routes.length);
assert.equal(resolveSmokeRoute('/users/[userId]',{'/users/[userId]':`/users/${id}`}),`/users/${id}`);
for(const path of ['//external.example/secret','/users/../settings','/users/a?token=secret','/users/%2e%2e','/users/secret#hash'])assert.equal(resolveSmokeRoute('/users/[userId]',{'/users/[userId]':path}),null);
assert.equal(resolveSmokeRoute('/users/[userId]',{}),null);
assert.equal(resolveSmokeRoute('/music',{}),'/music');

// Real data-reader module with bounded query transport and role adapters.
let role='admin',calls=[],failed=false;
function query() {
 const chain={then:resolve=>Promise.resolve({data:[],error:failed?{message:'sensitive provider error'}:null}).then(resolve)};
 for(const method of ['select','order','limit','gt','ilike','eq','not','lt','gte','lte','abortSignal'])chain[method]=(...args)=>{calls.push({method,args});return chain;};
 return chain;
}
const dataExports={};
const deps={'server-only':{},'next/navigation':{notFound:()=>{throw Error('denied');}},'./governance':{getOperationalRole:async()=>role},
 './supabase/server':{createAdminClient:async()=>({from:table=>{calls.push({method:'from',args:[table]});return query();}})},'./catalog-workspace-model':exports};
vm.runInNewContext(ts.transpileModule(await readFile(new URL('../lib/catalog-workspaces.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports:dataExports,AbortSignal,require:name=>{assert(name in deps);return deps[name];}});
for(const candidate of ['super_admin','admin','moderator','support','analyst','read_only_auditor',null]) {
 role=candidate;calls=[];
 if(!['super_admin','admin','moderator'].includes(role)){await assert.rejects(()=>dataExports.readTribeWorkspace(filters),/denied/);assert.equal(calls.length,0);}
 else {assert.equal((await dataExports.readTribeWorkspace(filters)).length,0);assert(calls.some(c=>c.method==='limit'&&c.args[0]===26));assert(calls.some(c=>c.method==='gt'&&c.args[1]===id));}
}
role='admin';failed=true;assert.equal(await dataExports.readMediaWorkspace(exports.catalogFilters('media',{})),null);
failed=false;calls=[];await dataExports.readMediaWorkspace(exports.catalogFilters('media',{kind:'whisper'}));
const selection=calls.find(c=>c.method==='select').args[0];
assert(!/content|title|image_url|media_labels/.test(selection),'no sensitive preview material fetched');
assert(calls.some(c=>c.method==='abortSignal'),'read transport is bounded');
calls=[];await dataExports.readMusicWorkspace(exports.catalogFilters('music',{state:'expiring',provider:'synthetic'}));
assert(calls.some(c=>c.method==='eq'&&c.args[0]==='provider'&&c.args[1]==='synthetic'));
assert(calls.some(c=>c.method==='gte')&&calls.some(c=>c.method==='lte'));
assert(!/preview_url|artwork_url/.test(calls.find(c=>c.method==='select').args[0]));
console.log(`PASS catalog model, bounded query/role adapters and ${routes.length}-route inventory; live pages are not verified`);
