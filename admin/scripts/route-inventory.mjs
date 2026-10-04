import {readdirSync} from 'node:fs';
import {join} from 'node:path';

// Discover routes from disk on every run: no hard-coded page-count claim.
export function dashboardRoutes(directory,segments=[]) {
  const entries=readdirSync(directory,{withFileTypes:true});
  const routes=entries.some(e=>e.isFile()&&e.name==='page.tsx')?[`/${segments.join('/')}`]:[];
  for(const entry of entries) {
    if(!entry.isDirectory()||entry.name.startsWith('@')||entry.name.startsWith('_'))continue;
    const next=entry.name.startsWith('(')&&entry.name.endsWith(')')?segments:[...segments,entry.name];
    routes.push(...dashboardRoutes(join(directory,entry.name),next));
  }
  return [...new Set(routes)].sort();
}
export function resolveSmokeRoute(template,fixtures) {
  if(!template.includes('['))return template;
  const supplied=fixtures[template];
  if(typeof supplied!=='string'||supplied.includes('?')||supplied.includes('#')||supplied.includes('%')||supplied.includes('\\'))return null;
  const expected=template.split('/'),actual=supplied.split('/');
  if(expected.length!==actual.length)return null;
  if(!expected.every((segment,i)=>segment.startsWith('[')?/^[a-zA-Z0-9_-]{1,80}$/.test(actual[i]):segment===actual[i]))return null;
  return supplied;
}
