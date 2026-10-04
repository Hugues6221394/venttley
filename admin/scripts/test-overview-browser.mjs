import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { STAFF_ROLES,canAccess } from '../lib/roles.ts';

export async function checkOverviewBrowser({browser,cookies,origin,userId,dbUrl,outputDir,proxy}) {
  assert(['127.0.0.1','localhost'].includes(new URL(dbUrl).hostname));assert(/^[a-f0-9-]{36}$/.test(userId));
  const sql=statement=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local overview fixture SQL failed');}};
  const literal=value=>`'${JSON.stringify(value).replaceAll("'","''")}'::jsonb`;
  const saved=JSON.parse(sql("SELECT COALESCE(jsonb_agg(to_jsonb(s)),'[]') FROM private.admin_overview_snapshots s"));
  assert.equal(sql("SELECT count(*) FROM cron.job WHERE jobname LIKE 'admin-overview-%' AND active"),'0','disable local Overview cron before isolated fixtures');
  const now=new Date().toISOString(); const today=now.slice(0,10);
  const fixtures={activity:{total_members:24810,new_members:186,previous_members:166,unique_writers:1284,vents:842,previous_vents:0,comments:942},queues:{moderation:24,appeals:8,support:12},reports:[{day:today,count:12}],regions:{total_members:24810,rows:[{country:'RW',count:9924},{country:'KE',count:6202}]}};
  const context=await browser.newContext({viewport:{width:1440,height:1100},reducedMotion:'reduce'});
  await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
  const page=await context.newPage();const errors=[];page.on('pageerror',()=>errors.push('runtime error'));
  const visit=()=>page.goto(`${origin}/overview`,{waitUntil:'networkidle'});
  const capture=async name=>{
    await page.evaluate(()=>{document.activeElement?.blur();window.scrollTo(0,0);});
    await page.waitForTimeout(100);
    await page.locator('header').first().evaluate(header=>{header.querySelectorAll('p').forEach(p=>{if(p.textContent?.startsWith('@'))p.textContent='@operator';});});
    await page.locator('aside .pill,aside .inbox-queue-badge').evaluateAll(nodes=>nodes.forEach(node=>node.remove()));
    const html=await page.evaluate(()=>{
      const shell=document.querySelector('.operator-shell-v2').cloneNode(true);
      shell.querySelectorAll('script').forEach(el=>el.remove());shell.querySelectorAll('a').forEach(el=>el.setAttribute('href','#'));
      shell.querySelectorAll('input').forEach(el=>{el.value='';el.removeAttribute('value');});
      const css=[...document.styleSheets].flatMap(sheet=>{try{return [...sheet.cssRules].map(r=>r.cssText);}catch{return [];}}).join('\n');
      return `<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style></head><body>${shell.outerHTML}</body></html>`;
    });
    await writeFile(resolve(outputDir,`${name}.html`),html);await page.screenshot({path:resolve(outputDir,`${name}.png`),fullPage:true});
  };
  try {
    for(const[panel,data]of Object.entries(fixtures))sql(`INSERT INTO private.admin_overview_snapshots(panel,payload,measured_at,error_code) VALUES('${panel}',${literal(data)},'${now}',NULL) ON CONFLICT(panel) DO UPDATE SET payload=EXCLUDED.payload,measured_at=EXCLUDED.measured_at,error_code=NULL`);
    for(const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}',account_status='active' WHERE user_id='${userId}'`);
      await visit();await page.getByRole('heading',{name:'A clear view of your community'}).waitFor();
      assert.equal(await page.getByRole('region',{name:'Unique writers · 24h',exact:true}).locator('strong').innerText(),'1,284');
      const queueLinks=await page.locator('.operator-queue-panel a').evaluateAll(nodes=>nodes.map(n=>n.getAttribute('href')));
      for(const href of queueLinks)assert(canAccess(role,href.split('?')[0]));
      assert.equal(queueLinks.length,['super_admin','admin'].includes(role)?3:role==='moderator'?2:role==='support'?1:0);
      for(const href of await page.locator('nav[aria-label="Overview workspace"] a').evaluateAll(nodes=>nodes.map(n=>n.getAttribute('href'))))assert(canAccess(role,href));
      console.log(`PASS overview role: ${role}`);
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);await visit();
    assert((await page.getByRole('region',{name:'Vents created · 24h',exact:true}).innerText()).includes('previous period was zero'));
    assert((await page.getByRole('region',{name:'Member regions',exact:true}).innerText()).includes('40%'));
    await page.getByLabel('Display window').selectOption('7');await page.getByText('View daily values',{exact:true}).click();
    assert.equal(await page.getByRole('table',{name:'Daily report submissions'}).locator('tbody tr').count(),7);
    await page.getByLabel('Display window').selectOption('30');assert.equal(await page.getByRole('table',{name:'Daily report submissions'}).locator('tbody tr').count(),30);
    await page.getByText('View daily values',{exact:true}).click();
    await page.locator('.operator-page-heading .h-eyebrow').evaluate(el=>el.textContent='CONTROL CENTER · SYNTHETIC FIXTURE');
    await capture('synthetic-overview');
    await page.getByRole('button',{name:'Metric definitions',exact:true}).click();
    await page.getByRole('dialog',{name:'Metric definitions'}).waitFor();await page.keyboard.press('Shift+Tab');
    assert(await page.evaluate(()=>document.querySelector('dialog').contains(document.activeElement)));
    await capture('synthetic-overview-definitions');await page.keyboard.press('Escape');
    assert(await page.getByRole('button',{name:'Metric definitions',exact:true}).evaluate(el=>el===document.activeElement));
    await page.setViewportSize({width:390,height:844});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await capture('synthetic-overview-mobile');
    await page.getByRole('button',{name:'Metric definitions',exact:true}).click();await page.getByRole('button',{name:'Close Metric definitions'}).click();
    await page.setViewportSize({width:1440,height:1100});
    proxy.control.mode='slow';const loading=page.goto(`${origin}/overview`,{waitUntil:'commit'});await loading;
    await page.getByRole('heading',{name:'A clear view of your community'}).waitFor();
    await page.getByRole('region',{name:'Registered members',exact:true}).waitFor();
    assert(await page.getByRole('status',{name:'Loading report volume'}).isVisible(),'slow secondary data must not block metrics');
    await page.getByLabel('Display window').waitFor();
    proxy.control.mode='failed';await visit();assert(await page.getByRole('heading',{name:'Report volume unavailable'}).isVisible());
    assert.equal(await page.getByRole('region',{name:'Unique writers · 24h',exact:true}).locator('strong').innerText(),'1,284');
    proxy.control.mode='normal';await page.getByRole('button',{name:'Refresh overview',exact:true}).click();await page.getByLabel('Display window').waitFor();
    sql("UPDATE private.admin_overview_snapshots SET measured_at=now()-interval '11 minutes' WHERE panel='activity'");await visit();assert(await page.getByRole('region',{name:'Community activity'}).getByText(/Stale snapshot/).isVisible());
    sql("UPDATE private.admin_overview_snapshots SET payload=NULL WHERE panel='activity'");await visit();assert(await page.getByRole('heading',{name:'Community activity unavailable'}).isVisible());assert(await page.getByLabel('Display window').isVisible());
    sql(`UPDATE public.users SET user_role='analyst' WHERE user_id='${userId}'`);await page.getByRole('button',{name:'Refresh overview',exact:true}).click();await page.getByText('Your role has no triage queues in this overview.',{exact:false}).waitFor();
    sql(`UPDATE public.users SET account_status='suspended' WHERE user_id='${userId}'`);await visit();assert.equal(await page.locator('.operator-page').count(),0);
    assert.equal(errors.length,0);console.log('PASS overview isolation, definitions drawer, keyboard/mobile, UTC chart filter, slow-panel streaming, failure/recovery, stale/missing snapshots and revocation');
  }finally{
    proxy.control.mode='normal';await context.close();sql('DELETE FROM private.admin_overview_snapshots');
    for(const row of saved)sql(`INSERT INTO private.admin_overview_snapshots SELECT * FROM jsonb_populate_record(NULL::private.admin_overview_snapshots,${literal(row)})`);
    sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}'`);
  }
}
