// Real model/reader/components with synthetic adapters. No live DB or browser claims.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
import React from 'react';
import * as jsx from 'react/jsx-runtime';
import {renderToStaticMarkup} from 'react-dom/server';
async function load(path,deps={}) {
 const exports={};vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText,{
  exports,Date,Map,Set,AbortSignal,require:name=>{assert(name in deps,`Unexpected import ${name}`);return deps[name];},
 });return exports;
}
const m=await load('../lib/analytics-model.ts');
for(const bad of [null,{},['7d'],'all','-1','90d<script>'])assert.equal(m.analyticsRange(bad),'30d');
for(const good of ['7d','30d','90d'])assert.equal(m.analyticsRange(good),good);
const engagement={total_users:10,active_1d:2,active_7d:3,active_30d:4,new_7d:1,new_30d:2,stickiness:.5,secret:'PRIVATE-SENTINEL'};
assert(!JSON.stringify(m.parseEngagement([engagement])).includes('PRIVATE-SENTINEL'));
for(const bad of [null,[],[engagement,engagement],[{...engagement,active_1d:-1}],[{...engagement,stickiness:NaN}],[{...engagement,active_7d:5}],[{...engagement,total_users:'10'}]])assert.equal(m.parseEngagement(bad),null);
const days=Array.from({length:7},(_,i)=>({day:`2026-09-${24+i}`,active_users:0,new_users:0}));
assert.equal(m.parseActiveDays(days,7).length,7);
assert.equal(m.parseActiveDays(days.slice(1),7),null);
assert.equal(m.parseActiveDays([...days.slice(0,6),days[0]],7),null);
assert.equal(m.parseActiveDays([{day:'2026-02-30',active_users:1,new_users:1}],1),null);
const retained={cohort_week:'2026-09-21',cohort_size:10,week_offset:0,retained:2};
assert.equal(m.parseRetention([retained]).length,1);
for(const bad of [[retained,retained],[{...retained,retained:11}],[{...retained,week_offset:6}],[retained,{...retained,week_offset:1,cohort_size:11}]])assert.equal(m.parseRetention(bad),null);
for(let pct=0;pct<=100;pct++)assert(m.retentionBand(pct,100)>=0&&m.retentionBand(pct,100)<=4);
const since='2026-09-24T00:00:00Z',until='2026-09-30T13:00:00Z',sample={created_at:'2026-09-30T01:00:00Z',category_name:'Calm',secret:'PRIVATE-SENTINEL'};
assert(!JSON.stringify(m.parseSample([sample],'posts',since,until)).includes('PRIVATE-SENTINEL'));
for(const bad of [[{...sample,created_at:'2026-09-23T01:00:00Z'}],Array(501).fill(sample),[{...sample,category_name:'a'.repeat(101)}]])assert.equal(m.parseSample(bad,'posts',since,until),null);
assert.equal(m.parseSample([{created_at:sample.created_at,resolved_at:'2026-09-29T01:00:00Z',is_resolved:true}],'reports',since,until),null);
assert.equal(m.sampleResolution([]).minutes,null);
assert.equal(m.sampleResolution([{created_at:'2026-09-30T01:00:00Z',resolved_at:'2026-09-30T01:30:00Z',is_resolved:true}]).minutes,30);
assert.equal(m.sampleResolution([{created_at:sample.created_at,resolved_at:null,is_resolved:true}]).observations,0);
const series=m.sampleSeries([{created_at:'2026-09-24T23:30:00-01:00'}],7,until);
assert.equal(series[0].count,0);assert.equal(series[1].count,1,'UTC calendar buckets, not sliding 24h');

const roles=await load('../lib/roles.ts');
let role='super_admin',calls=[],failure=null,payload=[engagement],throwTransport=false,clients=0;
function query(source) {
 const chain={then:(ok,no)=>{
  if(throwTransport)return Promise.reject(Error('PRIVATE-SENTINEL')).then(ok,no);
  const data=source==='posts'?[{created_at:new Date(Date.now()-1000).toISOString(),category_name:'Calm'}]:source==='reports'?[]:source==='posts_comments'||source==='post_likes'?[]:payload;
  return Promise.resolve({data,error:failure===source?{message:'PRIVATE-SENTINEL'}:null}).then(ok,no);
 }};
 for(const name of ['select','gte','lte','order','limit','is','abortSignal'])chain[name]=(...args)=>{calls.push({source,name,args});return chain;};
 return chain;
}
const reader=await load('../lib/analytics.ts',{
 'server-only':{},'next/navigation':{notFound:()=>{throw Error('DENIED');}},'./roles':roles,'./analytics-model':m,
 './supabase/server':{getRenderStaff:async()=>role?{role}:null,createAdminClient:async()=>{clients++;return {from:source=>query(source)};},createSsrClient:async()=>{clients++;return {rpc:(name,args)=>{calls.push({name,args});return query(name);}};}},
});
for(const candidate of [...roles.STAFF_ROLES,null,'suspended']) {
 role=candidate;clients=0;calls=[];
 if(roles.canAccess(role,'/analytics')){assert.equal((await reader.readAnalyticsPanel('engagement','30d')).data.total_users,10);assert.equal(clients,1);}
 else {await assert.rejects(()=>reader.readAnalyticsPanel('engagement','30d'),/DENIED/);assert.equal(clients,0,'no client constructed before access check');}
}
role='admin';calls=[];payload=days;
assert.equal((await reader.readAnalyticsPanel('daily','7d')).data.length,7);
assert.equal(calls.find(c=>c.name==='admin_active_users_daily').args.p_days,7);
assert(calls.some(c=>c.name==='abortSignal'&&c.args[0] instanceof AbortSignal));
payload=[];assert.equal((await reader.readAnalyticsPanel('engagement','30d')).data,null,'missing is unknown, not zero');
failure='admin_active_users_daily';assert.equal((await reader.readAnalyticsPanel('daily','7d')).data,null);failure=null;
throwTransport=true;assert.equal((await reader.readAnalyticsPanel('retention','30d')).data,null);throwTransport=false;
calls=[];failure='reports';const sampled=await reader.readAnalyticsPanel('samples','90d');
assert.equal(sampled.data.reports,null);assert.equal(sampled.data.comments.length,0);assert.equal(sampled.data.posts.length,1);
assert.equal(calls.filter(c=>c.name==='limit'&&c.args[0]===500).length,4);
assert.equal(calls.filter(c=>c.name==='abortSignal').length,4);
assert.equal(calls.filter(c=>c.name==='order'&&c.args[0]==='created_at'&&c.args[1].ascending===false).length,4);
for(const c of calls.filter(c=>c.name==='select'))assert(!/author_id|content|user_id|email|image_url/.test(c.args[0]));
assert(calls.some(c=>c.source==='posts'&&c.name==='is'&&c.args[0]==='deleted_at'));

const h=React.createElement;
const link={__esModule:true,default:({children,href})=>h('a',{href},children)};
const workspace=await load('../components/ui/operator-workspace.tsx',{'react/jsx-runtime':jsx,'next/link':link});
let panelData=null;
const components=await load('../components/analytics-panels.tsx',{'react/jsx-runtime':jsx,'@/lib/analytics-model':m,
 '@/lib/analytics':{readAnalyticsPanel:async()=>({data:panelData,receivedAt:until})},'./ui/operator-workspace':workspace,
 './ui/stat-card':{StatCard:({label,value,sub})=>h('section',null,h('h3',null,label),h('strong',null,value),sub)},
});
for(const name of ['AnalyticsEngagement','AnalyticsDaily','AnalyticsRetention','AnalyticsSamples']) {
 const markup=renderToStaticMarkup(await components[name]({range:'7d'}));
 assert(markup.includes('data-console-state="unavailable"'),name);assert(!markup.includes('PRIVATE-SENTINEL'));
}
panelData={...engagement,active_1d:0,active_7d:0,active_30d:0,stickiness:0};
assert(renderToStaticMarkup(await components.AnalyticsEngagement({range:'7d'})).includes('Not applicable'));
panelData={posts:[{...sample,category_name:'<script>not HTML</script>'}],comments:[],reactions:[],reports:null};
const sampleHtml=renderToStaticMarkup(await components.AnalyticsSamples({range:'7d'}));
assert(sampleHtml.includes('sample'));assert(sampleHtml.includes('Report records unavailable'));assert(sampleHtml.includes('&lt;script&gt;'));assert(!sampleHtml.includes('<script>'));
const chart=renderToStaticMarkup(h(components.AnalyticsBars,{rows:[{day:'2026-09-30',count:0}],label:'Synthetic'}));
assert(chart.includes('Peak 0'));assert(chart.includes('<summary>'));assert(chart.includes('scope="row"'));assert(chart.includes('height:0%'));
const heat=renderToStaticMarkup(h(components.RetentionTable,{rows:[retained]}));
assert(heat.includes('20%'));assert(heat.includes('2 of 10 accounts'));assert(heat.includes('No observation'));
console.log('PASS analytics models, six-role reader boundaries, bounded sample queries, independent safe failures, UTC buckets and accessible SSR chart values (synthetic, not live evidence)');
