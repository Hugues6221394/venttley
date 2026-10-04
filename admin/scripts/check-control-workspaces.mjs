import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
import React from 'react';
import * as jsx from 'react/jsx-runtime';
import {renderToStaticMarkup} from 'react-dom/server';

async function load(path,deps={},globals={}) {
  const exports={};
  vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true},
  }).outputText,{exports,AbortSignal,...globals,require:name=>{assert(name in deps,`Unexpected import: ${name}`);return deps[name];}});
  return exports;
}
const model=await load('../lib/control-plane-model.ts');
const valid={section:'campaigns',generated_at:'2026-10-01T10:00:00Z',privacy:'aggregate_only',data:{count:0,implemented:true,gap:false}};
assert.equal(model.parseControlSnapshot(valid,'campaigns').data.count,0);
for(const input of [null,[],{...valid,section:'experiments'},{...valid,privacy:'private'},{...valid,generated_at:'invalid'},
  {...valid,data:[]},{...valid,data:{count:Infinity}},{...valid,data:{count:{nested:true}}}])assert.equal(model.parseControlSnapshot(input,'campaigns'),null);
for(const input of [null,undefined,'PRIVATE-SENTINEL',true,-1,Infinity,'',{},'1e3',Number.MAX_SAFE_INTEGER+1])assert.equal(model.controlMetric(input),'Unavailable');
assert.equal(model.controlMetric(0),0);assert.equal(model.controlMetric('12'),12);
assert.equal(model.controlMetric(2,'hours'),'2h');
assert.equal(model.controlMetric('not-date','date'),'Unavailable');
assert.equal(model.controlMetric(valid.generated_at,'date'),'2026-10-01 10:00:00 UTC');
assert.equal(model.controlCapability(false),'gap');assert.equal(model.controlCapability(true),'available');
for(const item of [null,undefined,'true',0])assert.equal(model.controlCapability(item),'unknown');

let failure=null,calls=0;
const reader=await load('../lib/control-plane.ts',{'server-only':{},'./control-plane-model':model,
  '@/lib/supabase/server':{createSsrClient:async()=>({rpc:(name,args)=>{
    calls++;assert.equal(name,'admin_control_plane_snapshot');assert.equal(args.p_section,'campaigns');
    return {abortSignal:async signal=>{assert(signal instanceof AbortSignal);if(failure==='throw')throw Error('PRIVATE-SENTINEL');return {data:valid,error:failure?{message:'PRIVATE-SENTINEL'}:null};}};
  }})},
});
assert.equal((await reader.getControlSnapshot('campaigns')).snapshot.data.count,0);
for(const mode of ['throw','error']){failure=mode;const result=await reader.getControlSnapshot('campaigns');assert.equal(result.snapshot,null);assert(!result.error.includes('PRIVATE-SENTINEL'));}
assert.equal(calls,3);

const roles=await load('../lib/roles.ts');let role='moderator',reads=0;
const h=React.createElement;
const box=({children,title,label,hint,value})=>h('section',{},title,label,hint,value,children);
const page=await load('../components/control-plane-page.tsx',{
  react:React,'react/jsx-runtime':jsx,
  'next/link':{__esModule:true,default:({href,children})=>h('a',{href},children)},
  'next/navigation':{notFound:()=>{throw Error('denied');}},
  '@/lib/control-plane':{getControlSnapshot:async()=>{reads++;return {snapshot:null,error:'PRIVATE-SENTINEL'};}},
  '@/lib/control-plane-model':model,'@/lib/governance':{getOperationalRole:async()=>role},'@/lib/roles':roles,
  '@/components/ui/operator-workspace':{PanelSkeleton:box},'@/components/ui/page-header':{PageHeader:({title,actions})=>h('header',{},title,actions)},
  '@/components/ui/section':{Card:box,Row:box},'@/components/ui/stat-card':{StatCard:box},'@/components/ui/badge':{Badge:box},
  '@/components/ui/operations':{CapabilityNotice:box,DataWarning:box},'@/components/ui/icons':{CheckCircle2:()=>null,Lock:()=>null},
},{process:{env:{ADMIN_CONTROL_WORKSPACES_UI:'true'}}});
const config={section:'campaigns',title:'Campaigns',metrics:[{key:'count',label:'Count'}],capabilities:[{key:'implemented',label:'Capability',consequence:'Confirmed gap'}],operatingChecks:['Check context'],links:[{href:'/moderation',label:'Queue'},{href:'/staff',label:'Staff'}]};
for(const candidate of ['support','analyst','read_only_auditor',null]){role=candidate;await assert.rejects(()=>page.ControlPlanePage({config}),/denied/);}
assert.equal(reads,0,'unauthorized requests never read aggregates');
role='moderator';const tree=await page.ControlPlanePage({config});
assert.equal(reads,0,'authorized page shell does not await aggregates');
// Resolve real async child components using synthetic transport, not a browser.
async function resolve(node){
  if(Array.isArray(node))return React.Children.toArray(await Promise.all(node.map(resolve)));
  if(!React.isValidElement(node))return node;
  if(node.type===React.Suspense)return resolve(node.props.children);
  if(typeof node.type==='function')return resolve(await node.type(node.props));
  return h(node.type,{...node.props,key:node.key,children:await resolve(node.props.children)});
}
const html=renderToStaticMarkup(await resolve(tree));
assert(html.includes('unknown'));assert(!html.includes('Confirmed gap'));assert(!html.includes('PRIVATE-SENTINEL'));
assert(html.includes('href="/moderation"'));assert(!html.includes('href="/staff"'));assert(html.includes('href="/moderation/campaigns"'));
console.log('PASS operational snapshot validation, bounded transport, role gates, streaming shell and unknown rendering (synthetic; no live database/browser evidence)');
