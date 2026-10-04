// Only these two reviewed, self-contained security drafts are eligible here.
// Their transaction envelopes are removed in memory and replaced by one outer
// BEGIN/ROLLBACK per pair. Never promotes a migration or targets a remote DB.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {randomUUID} from 'node:crypto';
const root=fileURLToPath(new URL('../..',import.meta.url));
const names=['media_review_preserves_deletion','broadcast_visibility'];
const fingerprint=`SELECT md5(pg_get_functiondef('public.admin_set_media_status(text,uuid,text,text)'::regprocedure)||COALESCE((SELECT proacl::text FROM pg_proc WHERE oid='public.admin_set_media_status(text,uuid,text,text)'::regprocedure),'')||COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY policyname)::text FROM pg_policies p WHERE schemaname='public' AND tablename='broadcasts'),'[]'))`;
function body(sql,ending) {
 assert.equal((sql.match(/^BEGIN;$/gm)||[]).length,1,'one reviewed transaction envelope required');
 assert(new RegExp(`\n${ending};\\s*$`).test(sql),'expected transaction terminator');
 const inner=sql.replace(/^BEGIN;\r?\n/m,'').replace(new RegExp(`\n${ending};\\s*$`),'\n');
 assert(!/^\s*(?:BEGIN\s*;|COMMIT\b|ROLLBACK\b|END\s*;|\\)/im.test(inner),'unexpected transaction or psql command');
 return inner;
}
// BEGIN/END inside dollar-quoted functions are not transaction statements; the
// conservative envelope check below allows PL/pgSQL END only on its $$ line.
let config;
try{config=JSON.parse(execFileSync('supabase',['status','-o','json'],{cwd:root,encoding:'utf8',stdio:['ignore','pipe','ignore'],timeout:15000}));}
catch{throw Error('Local Supabase preflight unavailable. No draft executed.');}
for(const key of ['API_URL','DB_URL'])assert(['127.0.0.1','localhost'].includes(new URL(config[key]).hostname),'remote database refused');
const query=(sql)=>execFileSync('psql',[config.DB_URL,'-X','-At','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe'],timeout:30000,maxBuffer:1024*1024});
const output=resolve(root,'admin/.artifacts/verification',`${new Date().toISOString().replace(/[:.]/g,'-')}-${randomUUID().slice(0,8)}`);
await mkdir(output,{recursive:true});
const evidence={target:'local-only',mode:'rollback-only',drafts:[],limitations:['Only two security drafts, not governance ledgers','No migration replay, concurrency, staging or deployment evidence']};
for(const name of names) {
 const draft=body(await readFile(resolve(root,'supabase/pending',`${name}.sql`),'utf8'),'COMMIT');
 const test=body(await readFile(resolve(root,'supabase/pending',`${name}.test.sql`),'utf8'),'ROLLBACK');
 const before=query(fingerprint).trim();let text='',sqlState=null,failed=false;
 try {text=query(`BEGIN; SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='10s'; SET LOCAL search_path=public,extensions;\n${draft}\n${test}\nROLLBACK;`);}
 catch(error){failed=true;sqlState=String(error.stderr??'').match(/ERROR:\s+([A-Z0-9]{5})/)?.[1]??'unknown';}
 const restored=query(fingerprint).trim()===before;
 const ok=(text.match(/^ok \d+/gm)||[]).length,notOk=(text.match(/^not ok \d+/gm)||[]).length;
 const planned=Number(text.match(/^1\.\.(\d+)\s*$/m)?.[1]??0);
 const passed=!failed&&ok>0&&notOk===0&&planned===ok&&restored;
 evidence.drafts.push({name,status:passed?'passed':'failed',assertions:ok+notOk,failedAssertions:notOk,planned,sqlState,schemaRestored:restored});
 await writeFile(resolve(output,'security-drafts.json'),JSON.stringify(evidence,null,2));
 console.log(`${passed?'PASS':'FAIL'} ${name}: ${ok}/${planned} assertions; schema restored=${restored}${sqlState?`; SQLSTATE ${sqlState}`:''}`);
 if(!passed){process.exitCode=1;break;}
}
console.log(`Metadata: ${output}/security-drafts.json. No migration was applied.`);
