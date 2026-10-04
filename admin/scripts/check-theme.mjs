import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
import postcss from 'postcss';
import {createRequire} from 'node:module';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';

const code=ts.transpileModule(await readFile(new URL('../lib/theme-preference.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const model={};vm.runInNewContext(code,{exports:model});
const require=createRequire(import.meta.url);
const component={};
vm.runInNewContext(ts.transpileModule(await readFile(new URL('../components/theme-preference.tsx',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText,{
  exports:component,require:name=>name==='@/lib/theme-preference'?model:require(name),
});
assert.equal(renderToStaticMarkup(React.createElement(component.ThemePreferenceControl)),'','no provider means rollout off');
const markup=renderToStaticMarkup(React.createElement(component.ThemePreferenceProvider,null,React.createElement(component.ThemePreferenceControl)));
assert(markup.includes('for="console-appearance"'));assert(markup.includes('disabled=""'),'selector disabled before hydration');
assert(markup.includes('value="system" selected=""'));assert(markup.includes('aria-describedby="console-appearance-hint"'));
for(const [input,want] of [[null,'system'],['malicious','system'],['<script>','system'],['light','light'],['dark','dark'],['system','system'],[{},'system']])assert.equal(model.themePreference(input),want);
for(const saved of ['light','dark','system','invalid',null]) {
 const root={dataset:{themeUi:'enabled'}};
 vm.runInNewContext(model.themeBootstrap,{document:{documentElement:root},localStorage:{getItem:key=>{assert.equal(key,model.themePreferenceKey);return saved;}}});
 assert.equal(root.dataset.theme,model.themePreference(saved));
}
const off={dataset:{}};
vm.runInNewContext(model.themeBootstrap,{document:{documentElement:off},localStorage:{getItem(){throw Error('flag-off must not read storage');}}});
assert.equal(off.dataset.theme,undefined);
const blocked={dataset:{themeUi:'enabled'}};
vm.runInNewContext(model.themeBootstrap,{document:{documentElement:blocked},get localStorage(){throw Error('storage blocked');}});
assert.equal(blocked.dataset.theme,'system');

let stored='dark',denied=false,writes=[],events=new Map(),changes=[];
const storage={getItem:key=>{assert.equal(key,model.themePreferenceKey);return stored;},setItem:(key,value)=>{writes.push([key,value]);stored=value;}};
const win={get localStorage(){if(denied)throw Error('denied');return storage;},addEventListener:(kind,fn)=>events.set(kind,fn),removeEventListener:(kind,fn)=>{assert.equal(events.get(kind),fn);events.delete(kind);}};
const root={dataset:{theme:'system'}};
let binding=model.bindThemePreference(win,root,p=>changes.push(p));
assert.equal(root.dataset.theme,'dark');assert.equal(writes.length,0,'mount never writes');
assert.equal(binding.set('light'),true);assert.equal(root.dataset.theme,'light');assert.deepEqual(writes,[[model.themePreferenceKey,'light']]);
events.get('storage')({key:'unrelated',newValue:'dark',storageArea:storage});assert.equal(root.dataset.theme,'light');
events.get('storage')({key:model.themePreferenceKey,newValue:'dark',storageArea:{}});assert.equal(root.dataset.theme,'light');
events.get('storage')({key:model.themePreferenceKey,newValue:'dark',storageArea:storage});assert.equal(root.dataset.theme,'dark');
events.get('storage')({key:null,newValue:null,storageArea:storage});assert.equal(root.dataset.theme,'system');
denied=true;assert.equal(binding.set('dark'),false);assert.equal(root.dataset.theme,'dark','blocked storage still changes current tab');
binding.dispose();assert.equal(events.size,0);
binding=model.bindThemePreference(win,root,p=>changes.push(p));assert.equal(root.dataset.theme,'dark','blocked remount preserves current tab choice');binding.dispose();

const css=postcss.parse(await readFile(new URL('../app/themes.css',import.meta.url),'utf8'));
const palettes=[];css.walkRules(rule=>{if(rule.selector==='html[data-theme-ui="enabled"][data-theme="dark"]'||rule.selector==='html[data-theme-ui="enabled"]:not([data-theme="light"]):not([data-theme="dark"])') {
 const values={};rule.walkDecls(d=>values[d.prop]=d.value);palettes.push(values);
}});
assert.equal(palettes.length,2);assert.deepEqual(palettes[0],palettes[1],'system and explicit dark palettes stay identical');
const palette=palettes[0];
const rgb=hex=>hex.replace('#','').match(/../g).map(v=>parseInt(v,16)/255);
const luminance=c=>c.map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
const contrast=(a,b)=>{const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
const lightHeat={};css.walkRules(rule=>{if(rule.selector===':root')rule.walkDecls(d=>lightHeat[d.prop]=d.value);});
for(const colors of [lightHeat,palette])for(let band=0;band<5;band++) {
 const foreground=band<3?colors['--analytics-heat-text']:'#ffffff';
 assert(contrast(rgb(foreground),rgb(colors[`--analytics-heat-${band}`]))>=4.5,`retention band ${band} text contrast`);
}
for(const name of ['heading','copy','muted','accent'])for(const surface of ['panel','canvas','active'])assert(contrast(rgb(palette[`--theme-${name}`]),rgb(palette[`--theme-${surface}`]))>=4.5,`${name} on ${surface}`);
for(const status of ['success','warning','danger','info','purple'])assert(contrast(rgb(palette[`--theme-${status}`]),rgb(palette[`--theme-${status}-bg`]))>=4.5,status);
for(const fill of ['action','action-hover','danger-action'])assert(contrast(rgb('#ffffff'),rgb(palette[`--theme-${fill}`]))>=4.5,`white on ${fill}`);
for(const boundary of ['control-border','focus'])assert(contrast(rgb(palette[`--theme-${boundary}`]),rgb(palette['--theme-panel']))>=3,boundary);
// Actual Tailwind status pills use translucent foreground over the panel.
for(const status of ['ok','warn','danger','info']) {
 const fg=palette[`--console-${status}`].split(' ').map(v=>Number(v)/255),bg=rgb(palette['--theme-panel']);
 const tinted=fg.map((v,i)=>v*.15+bg[i]*.85);assert(contrast(fg,tinted)>=4.5,`${status} translucent badge`);
}
for(const [fg,bg] of [['#9d1f50','#ffffff'],['#1b6b3a','#ffffff'],['#835016','#ffffff'],['#31599e','#ffffff'],['#ffffff','#d12e65'],['#ffffff','#c1303d']])assert(contrast(rgb(fg),rgb(bg))>=4.5,`light ${fg} on ${bg}`);
console.log('PASS theme preference: exact storage enum, rollout, blocked storage, cross-tab updates, listener cleanup and palette contrast arithmetic. Browser accessibility is not certified.');
