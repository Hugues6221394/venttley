// Local synthetic actor only. Does not save URLs containing IDs, DOM, images,
// cookies, response bodies, console output or browser exception messages.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {canAccess,STAFF_ROLES,landingFor} from '../lib/roles.ts';
import {dashboardRoutes,resolveSmokeRoute} from './route-inventory.mjs';

export async function checkAllRoutesBrowser({browser,cookies,origin,userId,dbUrl,outputDir,root,fixtures={}}) {
  assert(['127.0.0.1','localhost'].includes(new URL(origin).hostname),'local browser required');
  assert(['127.0.0.1','localhost'].includes(new URL(dbUrl).hostname),'local DB required');
  assert(/^[0-9a-f-]{36}$/i.test(userId),'validated fixture actor');
  const routes=dashboardRoutes(resolve(root,'app/(dashboard)'));
  const fixtureMap={
    '/users/[userId]':`/users/${userId}`,
    '/privacy/requests/[userId]':`/privacy/requests/${userId}`,
    '/incidents/[incidentId]':'/incidents/moderation-sla',
    ...fixtures,
  };
  for(const key of Object.keys(fixtures))assert(routes.includes(key)&&key.includes('['),'only discovered dynamic fixtures allowed');
  const result={schemaVersion:1,startedAt:new Date().toISOString(),target:'local-only',routeCount:routes.length,
    cases:[],actorRestored:false,limitations:['Local AAL1 synthetic session: not an MFA mutation test','Missing dynamic fixtures block completion','Warning/unavailable UI is degraded, not passed','No production load, delivery, restore or field-vitals evidence']};
  const sql=statement=>execFileSync('psql',[dbUrl,'-X','-v','ON_ERROR_STOP=1','-c',statement],{stdio:'ignore'});
  let context;
  const save=()=>writeFile(resolve(outputDir,'route-coverage.json'),JSON.stringify(result,null,2));
  try {
    for(const role of [...STAFF_ROLES,'suspended','signed_out']) {
      sql(`UPDATE public.users SET user_role='${STAFF_ROLES.includes(role)?role:'super_admin'}',account_status='${role==='suspended'?'suspended':'active'}' WHERE user_id='${userId}'`);
      context=await browser.newContext({viewport:{width:1440,height:1000}});
      if(role!=='signed_out')await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
      const page=await context.newPage();let errors=0;
      page.on('pageerror',()=>errors++);
      for(const template of routes) {
        const allowed=STAFF_ROLES.includes(role)&&canAccess(role,template);
        let path=resolveSmokeRoute(template,fixtureMap);
        if(!path&&!allowed)path=template.replace(/\[[^\]]+\]/g,'00000000-0000-4000-8000-000000000001');
        if(!path) {result.cases.push({route:template,role,expected:'allowed',status:'blocked',reason:'missing-fixture'});continue;}
        const start=Date.now(),before=errors;
        let status='failed',reason='navigation';
        try {
          const response=await page.goto(`${origin}${path}`,{waitUntil:'networkidle',timeout:45000});
          await page.waitForFunction(()=>!document.querySelector('[data-console-loading]'),{},{timeout:15000});
          const actual=new URL(page.url()).pathname;
          if(allowed) {
            await page.locator('main h1').first().waitFor({timeout:10000});
            const reached=actual===(path==='/'?'/overview':path);
            const degraded=await page.locator('[data-console-state="unavailable"],[data-console-state="warning"]').count();
            status=reached&&response?.status()===200&&errors===before?(degraded?'degraded':'passed'):'failed';
            reason=status==='degraded'?'source-warning':status==='passed'?'rendered':'render-or-route';
          } else {
            const denied=STAFF_ROLES.includes(role)?actual===landingFor(role):!await page.locator('aside nav').count()&&actual!==path;
            status=denied&&errors===before?'passed':'failed';reason=denied?'access-denied':'authorization';
          }
        }catch { /* Never record raw exceptions, which may contain content/URLs. */ }
        result.cases.push({route:template,role,expected:allowed?'allowed':'denied',status,reason,durationMs:Date.now()-start});
        await save();
      }
      await context.close();context=null;
    }
  }finally {
    try {await context?.close();}
    finally {
      try {sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}'`);result.actorRestored=true;}
      finally {result.finishedAt=new Date().toISOString();await save();}
    }
  }
  assert(result.actorRestored&&result.cases.length===routes.length*8,'complete role matrix and restored actor required');
  assert(result.cases.every(row=>row.status==='passed'),'Route coverage has failed, degraded or missing-fixture cases; inspect redacted metadata');
  console.log(`PASS ${routes.length} route patterns across six roles, suspended staff and signed-out access; not production certification`);
}
