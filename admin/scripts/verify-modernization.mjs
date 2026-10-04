// Reproducible local gates, not staging capacity certification. Never push,
// deploy, enable a persistent pilot, or save credentials/request payloads.
import { execFileSync,spawn } from 'node:child_process';
import { mkdir,writeFile } from 'node:fs/promises';
import { dirname,resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { readVerificationControls } from './verification-controls.mjs';
import { executeVerification } from './verification-run.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2),suite=args[0]??'all';
if(suite==='--help') {
  console.log('Usage: node scripts/verify-modernization.mjs [all|notifications|incidents|governance|themes|routes|database]\nRequires local Supabase, psql, Node, and Playwright/Chrome. Routes require dynamic local fixture bindings via ADMIN_ROUTE_FIXTURES. Writes redacted stage results under .artifacts/verification. No production targets. Pending SQL drafts are not automatically applied.');
  process.exit(0);
}
if(args.length>1||!['all','notifications','incidents','governance','themes','routes','database'].includes(suite))throw Error('Invalid suite. Use --help.');
let config;
const preflight=async()=>{
  config=JSON.parse(execFileSync('supabase',['status','-o','json'],{cwd:resolve(root,'..'),encoding:'utf8',stdio:['ignore','pipe','ignore'],timeout:15000}));
  for(const key of ['API_URL','DB_URL'])if(!['127.0.0.1','localhost'].includes(new URL(config[key]).hostname))throw Error('Local target required');
};
const sql=query=>execFileSync('psql',[config.DB_URL,'-X','-At','-v','ON_ERROR_STOP=1','-c',query],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();
const controls=()=>readVerificationControls(sql);
const runId=`${new Date().toISOString().replace(/[:.]/g,'-')}-${randomUUID().slice(0,8)}`;
const stages=[
  {name:'typecheck',command:'npm',args:['run','typecheck'],cwd:root},
  {name:'analytics-contracts',command:'npm',args:['run','check:analytics'],cwd:root},
  {name:'database',command:'supabase',args:['test','db','--local'],cwd:resolve(root,'..')},
];
const browser=(name,flags)=>({name,command:process.execPath,args:['scripts/profile-console.mjs'],cwd:root,env:{ADMIN_PROFILE_SAMPLES:'0',ADMIN_THEME_UI:'false',ADMIN_PROFILE_LABEL:`verification/${runId}/${name}`,...flags}});
if(suite==='all'||suite==='themes')stages.push(
  {name:'theme-contracts',command:'npm',args:['run','check:theme'],cwd:root},
  browser('themes',{ADMIN_THEME_ASSERT:'1'}),
  browser('themes-rollback',{ADMIN_THEME_ASSERT:'rollback'}),
  {name:'analytics-browser',command:'npm',args:['run','check:analytics-browser'],cwd:root},
);
if(suite==='all'||suite==='governance')stages.push({name:'governance-contracts',command:'npm',args:['run','check:governance-ledgers'],cwd:root});
if(suite==='all'||suite==='routes')stages.push(
  {name:'catalog-contracts',command:'npm',args:['run','check:catalog'],cwd:root},
  browser('route-matrix',{ADMIN_ALL_ROUTES_ASSERT:'1',ADMIN_CATALOG_WORKSPACES_UI:'true',ADMIN_CONTROL_WORKSPACES_UI:'true'}),
);
if(suite==='all'||suite==='notifications')stages.push(
  browser('job-report',{ADMIN_JOB_REPORT_ASSERT:'1'}),
  browser('moderation-notices',{ADMIN_MODERATION_NOTICES_ASSERT:'1'}),
  browser('recovery',{ADMIN_RECOVERY_ASSERT:'1'}),
  browser('inbox',{ADMIN_INBOX_ASSERT:'1',ADMIN_MODERN_SHELL_ASSERT:'1'}),
);
if(suite==='all'||suite==='incidents')stages.push(browser('incidents',{ADMIN_INCIDENT_ASSERT:'1'}));
if(suite==='all'||suite==='governance')stages.push(browser('governance',{ADMIN_STAFF_ASSERT:'1'}));
if(suite==='all')stages.push(
  browser('shell',{ADMIN_SHELL_ASSERT:'1',ADMIN_MODERN_SHELL_ASSERT:'1'}),
  browser('overview',{ADMIN_OVERVIEW_ASSERT:'1'}),
  browser('attention',{ADMIN_ATTENTION_ASSERT:'1'}),
  browser('workflows',{ADMIN_WORKFLOW_ASSERT:'1'}),
);
// Remove inherited assertion switches so each stage tests its own rollout.
const env={...process.env};
for(const key of Object.keys(env))if(/^ADMIN_.*_ASSERT$/.test(key)||key==='ADMIN_PROFILE_SKIP_BUILD')delete env[key];
const output=resolve(root,'.artifacts/verification',runId);await mkdir(output,{recursive:true});
const result=await executeVerification({suite,stages,preflight,controls,log:message=>console.log(message),
  save:record=>writeFile(resolve(output,`${suite}.json`),JSON.stringify(record,null,2)),
  run:stage=>new Promise((resolve,reject)=>{
      const child=spawn(stage.command,stage.args,{cwd:stage.cwd,env:{...env,...stage.env},stdio:['ignore','pipe','pipe']});
      // Child commands can print SQL fixtures or Auth errors on failure. Keep
      // the evidence file metadata-only; rerun the named gate to investigate.
      child.stdout.resume();child.stderr.resume();child.once('error',reject);child.once('exit',resolve);
    }),
});
console.log(`Verification ${result.status}. Metadata: .artifacts/verification/${runId}/${suite}.json`);
if(result.status!=='local_passed') {console.error(`Gate unavailable or failed: ${result.reason}. No production readiness is established.`);process.exitCode=1;}
else console.log('Local verification finished. This does not establish staging or production readiness.');
