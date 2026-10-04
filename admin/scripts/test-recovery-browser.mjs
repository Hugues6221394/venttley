// Disposable local fixtures only. No authentication material in artifacts.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID,createHmac } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { STAFF_ROLES } from '../lib/roles.ts';
function totp(secret){
  const bits=[...secret.replace(/=+$/,'').toUpperCase()].map(c=>'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5,'0')).join('');
  const key=Buffer.from(bits.match(/.{8}/g).map(b=>parseInt(b,2))),counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));
  const hash=createHmac('sha1',key).update(counter).digest(),offset=hash.at(-1)&15;return String((hash.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0');
}
export async function checkRecoveryBrowser({browser,cookies,origin,userId,dbUrl,outputDir,auth}) {
  assert.equal(new URL(dbUrl).hostname,'127.0.0.1');
  const sql=statement=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local recovery fixture query failed');}};
  const control=JSON.parse(sql('SELECT row_to_json(c) FROM private.staff_inbox_control c'));
  assert.equal(control.enabled,false,'refuse active pilot');
  const cron=sql("SELECT active FROM cron.job WHERE jobname='staff-inbox-dispatch'");
  const source=randomUUID(),ids=Array.from({length:31},()=>randomUUID());let context;
  try {
    sql(`SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname='staff-inbox-dispatch';
      INSERT INTO private.support_cases(support_case_id,source_kind,category,status,sla_due_at,created_by,assigned_to) VALUES('${source}','other','technical','open',now()+interval '1 day','${userId}','${userId}');
      INSERT INTO private.staff_event_outbox(event_id,event_key,kind,source_id,intended_recipient,severity,status,attempts,last_error_code,created_at)
      VALUES ${ids.map((id,i)=>`('${id}','recovery-browser-${id}','support_assigned','${source}','${userId}','warning','failed',5,'57014','2000-01-01T00:${String(i).padStart(2,'0')}:00Z')`).join(',')};
      INSERT INTO private.staff_inbox_deliveries(event_id,recipient_id,read_at) VALUES('${ids[0]}','${userId}','2000-01-01T00:00:00Z');`);
    context=await browser.newContext({viewport:{width:1536,height:1024},reducedMotion:'reduce'});
    const applyCookies=()=>context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    await applyCookies();const page=await context.newPage(),errors=[];page.on('pageerror',()=>errors.push('page error'));
    const visit=()=>page.goto(`${origin}/inbox/operations`,{waitUntil:'networkidle'});
    for(const role of STAFF_ROLES){
      sql(`UPDATE public.users SET user_role='${role}',account_status='active' WHERE user_id='${userId}'`);
      await visit();assert.equal(new URL(page.url()).pathname,role==='super_admin'?'/inbox/operations':'/overview');
      const response=await context.request.get(`${origin}/inbox/operations/data`,{maxRedirects:0});
      if(role==='super_admin')assert.equal(response.status(),200);else assert.notEqual(response.status(),200);
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);await visit();
    const refresh=async()=>{await page.getByRole('button',{name:'Refresh recovery',exact:true}).click();await page.getByRole('button',{name:'Refresh recovery',exact:true}).waitFor();};
    const open=async()=>{await page.getByRole('button',{name:'Review retry',exact:true}).first().click();const d=page.getByRole('dialog',{name:'Review notification retry'});await d.waitFor();return d;};
    const save=async d=>{await d.getByRole('button',{name:'Queue retry',exact:true}).click();await d.getByRole('button',{name:'Confirm queue retry',exact:true}).click();};
    let d=await open();assert.equal(await d.getByRole('button',{name:'Queue retry',exact:true}).isDisabled(),true,'DB rollback disables retry');await page.keyboard.press('Escape');
    assert.equal((await context.request.get(`${origin}/inbox/operations/data?afterId=bad`)).status(),400);
    await page.getByRole('button',{name:'Next failures'}).click();await page.waitForFunction(()=>document.querySelectorAll('main tbody tr').length===1);
    await page.getByRole('button',{name:'First page',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('main tbody tr').length===30);
    sql("UPDATE private.staff_inbox_control SET enabled=true,worker_at=now()");await refresh();
    d=await open();await d.locator('select[name=reason_code]').selectOption('configuration_fixed');await save(d);
    await d.getByRole('alert').filter({hasText:'Complete MFA'}).waitFor();
    assert.equal(await d.locator('select[name=reason_code]').inputValue(),'configuration_fixed');
    assert.equal(sql(`SELECT status FROM private.staff_event_outbox WHERE event_id='${ids[0]}'`),'failed');
    await page.keyboard.press('Escape');assert(await page.getByRole('button',{name:'Review retry',exact:true}).first().evaluate(el=>el===document.activeElement));
    const factor=await auth.auth.mfa.enroll({factorType:'totp',friendlyName:'Disposable recovery fixture'});assert.equal(factor.error,null);
    const verified=await auth.auth.mfa.challengeAndVerify({factorId:factor.data.id,code:totp(factor.data.totp.secret)});assert.equal(verified.error,null);await applyCookies();
    // Synthetic screenshots only: replace health counts, timestamps and chrome
    // identity; remove all IDs/links/inputs/scripts from exported static HTML.
    async function capture(name){
      const html=await page.evaluate(()=>{
        const shell=document.querySelector('.operator-shell-v2').cloneNode(true);
        shell.querySelectorAll('script,input[type=hidden]').forEach(el=>el.remove());shell.querySelectorAll('a').forEach(el=>el.setAttribute('href','#'));
        shell.querySelectorAll('header p').forEach(el=>{if(el.textContent.startsWith('@'))el.textContent='@operator';});
        shell.querySelectorAll('.recovery-metric strong').forEach((el,i)=>el.textContent=['Recent','2','31','Enabled'][i]);
        shell.querySelectorAll('.recovery-metric p').forEach((el,i)=>{if(i===0)el.textContent='Synthetic worker timestamp';});
        shell.querySelectorAll('.operator-freshness').forEach(el=>el.textContent='Synthetic snapshot · visible refresh every 30 seconds');
        shell.querySelectorAll('dialog').forEach(el=>{el.setAttribute('open','');el.style.zIndex='100';});
        const css=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules].map(r=>r.cssText)}catch{return []}}).join('\n');
        return `<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style></head><body>${shell.outerHTML}</body></html>`;
      });
      await writeFile(resolve(outputDir,`${name}.html`),html);
      const preview=await context.newPage();await preview.setViewportSize(page.viewportSize());await preview.setContent(html);await preview.screenshot({path:resolve(outputDir,`${name}.png`)});await preview.close();
    }
    await visit();await capture('synthetic-recovery-queue');d=await open();await d.locator('select[name=reason_code]').selectOption('reviewed_retry');await capture('synthetic-recovery-drawer');
    await page.keyboard.press('Shift+Tab');assert(await d.evaluate(el=>el.contains(document.activeElement)));
    await page.setViewportSize({width:390,height:844});assert(await d.evaluate(el=>el.getBoundingClientRect().width<=innerWidth));await capture('synthetic-recovery-mobile');
    await page.setViewportSize({width:1536,height:1024});
    await page.route('**/inbox/operations',async route=>{if(route.request().method()==='POST')await new Promise(r=>setTimeout(r,900));await route.continue();});
    const operation=await d.locator('input[name=operation_id]').inputValue();await save(d);
    await page.keyboard.press('Escape');assert(await d.isVisible(),'pending command cannot be dismissed');
    await d.getByRole('status').filter({hasText:'Queued again. Delivery is not confirmed.'}).waitFor();
    assert.equal(sql(`SELECT status FROM private.staff_event_outbox WHERE event_id='${ids[0]}'`),'pending');
    assert.equal(sql(`SELECT read_at IS NOT NULL FROM private.staff_inbox_deliveries WHERE event_id='${ids[0]}'`),'t');
    await page.unroute('**/inbox/operations');
    const retry=await auth.rpc('admin_retry_staff_notification',{p_operation:operation,p_event:ids[0],p_reason_code:'reviewed_retry'});assert.equal(retry.error,null,'same operation replays safely');
    await page.waitForFunction(()=>document.querySelectorAll('main tbody tr').length===30);
    assert(await d.getByText('Queued again. Delivery is not confirmed. Existing read states are unchanged.',{exact:true}).isVisible(),'polling must not discard success');
    await page.keyboard.press('Escape');assert(await page.locator('#recovery-refresh').evaluate(el=>el===document.activeElement),'removed trigger focuses refresh');
    d=await open();await d.locator('select[name=reason_code]').selectOption('reviewed_retry');
    const event=await d.locator('input[name=event_id]').inputValue();sql(`UPDATE private.staff_event_outbox SET status='pending' WHERE event_id='${event}'`);await save(d);
    await d.getByRole('alert').filter({hasText:'no longer failed'}).waitFor();await page.keyboard.press('Escape');
    const authorized=await (await context.request.get(`${origin}/inbox/operations/data`)).json();
    await page.route('**/inbox/operations/data*',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({...authorized,health:null})}));await refresh();
    assert.equal(await page.locator('.recovery-metric strong').nth(1).textContent(),'—','health failure never becomes zero');
    d=await open();assert.equal(await d.getByRole('button',{name:'Queue retry',exact:true}).isDisabled(),true,'unknown health disables retry');await page.keyboard.press('Escape');
    await page.unroute('**/inbox/operations/data*');
    await page.route('**/inbox/operations/data*',route=>route.fulfill({status:503,contentType:'application/json',body:'{}'}));await refresh();
    await page.getByRole('alert').filter({hasText:'Counts are unknown'}).waitFor();assert.equal(await page.locator('main tbody tr').count(),0);
    assert.equal(await page.locator('.recovery-metric strong').nth(1).textContent(),'—');await page.unroute('**/inbox/operations/data*');await refresh();
    let reads=0;const countRead=request=>{if(request.url().includes('/inbox/operations/data'))reads++;};page.on('request',countRead);
    await page.waitForTimeout(31_500);assert(reads>=1,'visible recovery polls');
    await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'));});
    const hiddenReads=reads;await page.waitForTimeout(31_500);assert.equal(reads,hiddenReads,'hidden recovery stops polling');
    await page.evaluate(()=>{delete document.hidden;document.dispatchEvent(new Event('visibilitychange'));window.dispatchEvent(new Event('focus'));});
    await page.waitForTimeout(1200);assert(reads>hiddenReads,'focus refresh');page.off('request',countRead);
    sql(`UPDATE public.users SET account_status='suspended' WHERE user_id='${userId}'`);await refresh();
    await page.getByRole('alert').filter({hasText:'Recovery access is unavailable'}).waitFor();assert.equal(await page.locator('main tbody tr').count(),0);
    assert.equal(errors.length,0,'no runtime errors');
    console.log('PASS recovery: six roles, current revocation, cursor, off state, real MFA, retained reason, idempotency/read state, conflict, unknown counts, keyboard/mobile and retained receipt');
  }finally{
    await context?.close();
    sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      UPDATE private.staff_inbox_control SET enabled=false;
      DELETE FROM private.staff_inbox_deliveries WHERE event_id IN (SELECT event_id FROM private.staff_event_outbox WHERE source_id='${source}');
      DELETE FROM private.staff_event_outbox WHERE source_id='${source}';DELETE FROM private.support_cases WHERE support_case_id='${source}';
      UPDATE private.staff_inbox_control SET audience_roles=ARRAY[${control.audience_roles.map(r=>`'${r}'`).join(',')}],worker_at=${control.worker_at?`'${control.worker_at}'::timestamptz`:'NULL'};
      SELECT cron.alter_job(jobid,active:=${cron==='t'}) FROM cron.job WHERE jobname='staff-inbox-dispatch';`);
  }
}
