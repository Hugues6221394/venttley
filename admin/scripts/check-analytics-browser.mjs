// Isolated synthetic component/browser check; never authenticates or contacts DB.
// Exercises actual SSR components and the built CSS, not an authenticated journey.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
import React from 'react';
import * as jsx from 'react/jsx-runtime';
import {renderToStaticMarkup} from 'react-dom/server';
const root=fileURLToPath(new URL('..',import.meta.url));
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE?pathToFileURL(process.env.PLAYWRIGHT_MODULE).href:'playwright');
async function load(path,deps) {
 const exports={};vm.runInNewContext(ts.transpileModule(await readFile(new URL(path,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText,{exports,require:name=>{assert(name in deps);return deps[name];}});return exports;
}
const h=React.createElement;
const model=await load('../lib/analytics-model.ts',{});
const workspace=await load('../components/ui/operator-workspace.tsx',{'react/jsx-runtime':jsx,'next/link':{__esModule:true,default:({href,children})=>h('a',{href},children)}});
const panels=await load('../components/analytics-panels.tsx',{'react/jsx-runtime':jsx,'@/lib/analytics-model':model,'@/lib/analytics':{readAnalyticsPanel:()=>{throw Error('No source access in synthetic fixture');}},'./ui/operator-workspace':workspace,'./ui/stat-card':{StatCard:()=>null}});
const rows=Array.from({length:6},(_,i)=>({cohort_week:'2026-09-21',cohort_size:100,week_offset:i,retained:i*20}));
const markup=renderToStaticMarkup(h(workspace.OperatorPage,{title:'Synthetic analytics',subtitle:'No member or production data'},
 h(workspace.OperatorPanel,{title:'Synthetic retention'},h(panels.RetentionTable,{rows})),
 h(workspace.OperatorPanel,{title:'Synthetic daily activity'},h(panels.AnalyticsBars,{rows:[{day:'2026-09-29',count:0},{day:'2026-09-30',count:12}],label:'Synthetic daily activity'})),
 h(workspace.PanelUnavailable,{label:'Synthetic unavailable source',retryHref:'/analytics'}),
));
async function cssFiles(dir){const result=[];for(const entry of await readdir(dir,{withFileTypes:true})){const path=join(dir,entry.name);if(entry.isDirectory())result.push(...await cssFiles(path));else if(entry.name.endsWith('.css'))result.push(path);}return result;}
const files=await cssFiles(join(root,'.next/static'));assert(files.length,'Production CSS build required');
const css=(await Promise.all(files.map(path=>readFile(path,'utf8')))).join('\n');
assert(css.includes('analytics-retention-cell'),'Build the current source before this check');
let browser;
try {
 browser=await chromium.launch({channel:process.env.ADMIN_BROWSER_CHANNEL??'chrome',headless:true});
 let checked=0;
 for(const mode of ['off','light','dark','system'])for(const width of [1440,320]) {
  const context=await browser.newContext({viewport:{width,height:900},colorScheme:'dark',reducedMotion:'reduce',javaScriptEnabled:true});
  // Test scripts operate on synthetic DOM only. All network access is blocked.
  await context.route('**/*',route=>route.abort());
  const page=await context.newPage();
  await page.setContent(`<!doctype html><html lang="en" ${mode==='off'?'':`data-theme-ui="enabled" data-theme="${mode}"`}><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style></head><body><main>${markup}</main></body></html>`);
  const findings=await page.evaluate(()=>{
   const rgb=value=>(value.match(/[\d.]+/g)||[]).slice(0,3).map(Number);
   const lum=values=>values.map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
   const ratio=(a,b)=>{const x=lum(rgb(a)),y=lum(rgb(b));return(Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
   const cells=[...document.querySelectorAll('.analytics-retention-cell')];
   return {contrasts:cells.map(el=>{const s=getComputedStyle(el);return ratio(s.color,s.backgroundColor);}),
    overflow:document.documentElement.scrollWidth>innerWidth+1,scheme:getComputedStyle(document.documentElement).colorScheme,
    // Synthetic fixture geometry only, never member DOM or production content.
    overflowElements:[...document.querySelectorAll('main,main > *,main section,main header,.operator-table-scroll')].filter(el=>el.getBoundingClientRect().right>innerWidth+1).map(el=>({tag:el.tagName,class:el.className,width:Math.round(el.getBoundingClientRect().width)})),
    firstBar:document.querySelector('.analytics-bars span').getBoundingClientRect().height,
    tableScrollable:[...document.querySelectorAll('.operator-table-scroll')].every(el=>el.tabIndex===0 && ['auto','scroll'].includes(getComputedStyle(el).overflowX))};
  });
  assert(findings.contrasts.every(n=>n>=4.5),`${mode}/${width}: rendered heatmap contrast`);
  assert.equal(findings.scheme,mode==='dark'||mode==='system'?'dark':'light');
  assert.equal(findings.firstBar,0,'zero values must not render positive bars');
  assert.equal(findings.overflow,false,`${mode}/${width}: page reflow ${JSON.stringify(findings.overflowElements)}`);assert(findings.tableScrollable);
  const summary=page.getByText('View synthetic daily activity values',{exact:true});
  await summary.focus();await page.keyboard.press('Enter');
  assert(await page.getByRole('table',{name:'Synthetic daily activity',exact:true}).isVisible(),'keyboard opens values');
  assert.equal(await page.locator('[data-console-state="unavailable"]').count(),1);
  if(mode!=='off')assert(await summary.evaluate(el=>getComputedStyle(el).outlineStyle!=='none'),'visible keyboard focus');
  await context.close();checked++;
 }
 console.log(`PASS ${checked} synthetic browser cases: built CSS, rendered retention contrast, narrow reflow, table keyboard access and zero bars. Not live roles, RLS, screen-reader or full-route evidence.`);
} finally {await browser?.close();}
