import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {randomUUID,createHmac} from 'node:crypto';
import {STAFF_ROLES,canAccess} from '../lib/roles.ts';
import {writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {syntheticShell} from './synthetic-shell.mjs';
import {runMonitor} from './monitor-notifications.mjs';

function totp(secret){
 const bits=[...secret.replace(/=+$/,'').toUpperCase()].map(c=>'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5,'0')).join('');
 const key=Buffer.from(bits.match(/.{8}/g).map(b=>parseInt(b,2))),counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));
 const hash=createHmac('sha1',key).update(counter).digest(),offset=hash.at(-1)&15;return String((hash.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0');
}
export async function checkIncidentBrowser({browser,cookies,origin,userId,dbUrl,auth,outputDir,monitorEnv}){
 assert.equal(new URL(dbUrl).hostname,'127.0.0.1');assert(/^[a-f0-9-]{36}$/.test(userId));
 const sql=s=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',s],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local incident fixture query failed');}};
 const control=JSON.parse(sql('SELECT row_to_json(c) FROM private.incident_control c'));
 assert(control.audience_roles.every(r=>['super_admin','admin'].includes(r)));
 const inbox=JSON.parse(sql('SELECT row_to_json(c) FROM private.staff_inbox_control c'));
 assert.equal(control.enabled,false,'refuse an active incident pilot');assert.equal(control.notifications_enabled,false);assert.equal(inbox.enabled,false);
 const cron=JSON.parse(sql("SELECT coalesce(json_agg(json_build_object('id',jobid,'active',active)),'[]') FROM cron.job WHERE jobname IN ('staff-inbox-dispatch','staff-incident-deadlines')"));
 let context,incident;
 try{
  sql("SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname IN ('staff-inbox-dispatch','staff-incident-deadlines')");
  context=await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'});
  const applyCookies=()=>context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
  await applyCookies();const page=await context.newPage(),errors=[];page.on('pageerror',()=>errors.push('page error'));
  const visit=path=>page.goto(`${origin}${path}`,{waitUntil:'networkidle',timeout:60000});
  const capture=async name=>{
   const shell=await syntheticShell(page);
   const main=await page.locator('main').evaluate(el=>{
    const clone=el.cloneNode(true);clone.querySelectorAll('script,input[type=hidden],dialog').forEach(e=>e.remove());
    clone.querySelectorAll('input,textarea').forEach(e=>{e.value='';e.removeAttribute('value');e.textContent='';});
    clone.querySelectorAll('a').forEach(e=>e.setAttribute('href','#'));clone.querySelectorAll('form').forEach(e=>e.removeAttribute('action'));
    return clone.innerHTML.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,'synthetic-reference');
   });
   await writeFile(resolve(outputDir,name),shell.replace('<section class="operator-queue-panel" aria-label="Synthetic attention fixture"></section>',main));
  };
  for(const role of STAFF_ROLES){sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);for(const path of ['/incidents','/incidents/new']){await visit(path);assert.equal(new URL(page.url()).pathname,canAccess(role,path)?path:'/overview',`${role} direct ${path}`);}}
  sql(`UPDATE public.users SET user_role='super_admin',display_name='Console Test' WHERE user_id='${userId}'`);
  const denied=await auth.rpc('admin_configure_incidents',{p_operation:randomUUID(),p_enabled:true});assert.match(denied.error?.message??'',/aal2_required/);
  const factor=await auth.auth.mfa.enroll({factorType:'totp',friendlyName:'Disposable incident fixture'});assert.equal(factor.error,null);
  const verified=await auth.auth.mfa.challengeAndVerify({factorId:factor.data.id,code:totp(factor.data.totp.secret)});assert.equal(verified.error,null);await applyCookies();
  assert.equal((await auth.rpc('admin_configure_incidents',{p_operation:randomUUID(),p_enabled:true})).error,null);
  assert.equal((await auth.rpc('admin_configure_incident_notices',{p_operation:randomUUID(),p_enabled:true})).error,null);
  assert.equal((await auth.rpc('admin_configure_incident_audience',{p_operation:randomUUID(),p_roles:['super_admin']})).error,null);
  sql(`UPDATE public.users SET user_role='admin' WHERE user_id='${userId}'`);
  assert.equal((await auth.rpc('admin_incident_queue')).data?.enabled,false,'direct API rejects out-of-pilot admin');
  sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
  sql("UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin','admin']");
  await visit('/incidents/new');await capture('synthetic-incident-declare.html');const form=page.getByRole('form',{name:'Declare incident'});
  await form.getByLabel('Incident title',{exact:true}).fill('Synthetic response test');await form.locator('input[name=services][value=push]').check();
  const commander=form.locator('.incident-staff').first();await commander.getByRole('button',{name:'Find staff',exact:true}).click();await commander.getByRole('button',{name:'Console Test',exact:true}).click();
  await form.getByLabel('Response deadline (UTC)',{exact:true}).fill(new Date(Date.now()+3600000).toISOString().slice(0,16));
  await form.getByLabel('Internal coordination note',{exact:true}).fill('Synthetic internal note');
  await form.getByRole('button',{name:'Declare incident',exact:true}).click();await form.getByRole('button',{name:'Confirm declare incident',exact:true}).click();
  await form.getByRole('link',{name:'Open saved incident'}).waitFor();
  incident=(await form.getByRole('link',{name:'Open saved incident'}).getAttribute('href')).split('/').at(-1);assert(/^[a-f0-9-]{36}$/.test(incident));
  await form.getByRole('link',{name:'Open saved incident'}).click();await page.waitForURL(`**/incidents/records/${incident}`);
  const detailPath=`/incidents/records/${incident}`;
  sql('SELECT private.process_staff_inbox(100)');
  assert((await runMonitor(monitorEnv)).reasons.includes('incident_deadline_worker_stale'),'independent HTTP probe detects missing producer heartbeat');
  assert((await auth.rpc('staff_notification_monitor')).error,'human session cannot call machine monitor');
  sql('SELECT private.reconcile_incident_deadlines()');
  const health=await runMonitor(monitorEnv);
  assert(!health.reasons.includes('incident_deadline_worker_stale'),'real producer run advances independent heartbeat');
  assert(health.reasons.includes('incident_deadline_scheduler_inactive'),'probe detects paused scheduler despite fresh heartbeat');
  await visit('/incidents?filter=active');
  const badge=page.locator('aside a[href="/incidents?filter=active"] .inbox-queue-badge');
  await badge.waitFor();
  const activeCount=Number(sql("SELECT count(*) FROM private.operational_incidents WHERE status NOT IN ('resolved','reviewed')"));
  assert.equal(await badge.textContent(),activeCount>99?'99+':String(activeCount),'incident badge matches source queue');
  await page.route('**/inbox/data?mode=attention',route=>route.abort());
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
  await page.locator('aside a[href="/incidents?filter=active"] [aria-label="Active incidents: count unavailable or stale"]').waitFor({timeout:45000});
  await page.unroute('**/inbox/data?mode=attention');
  await visit(detailPath);
  await page.getByRole('heading',{name:'Synthetic response test',exact:true}).waitFor();
  await capture('synthetic-incident-detail.html');
  if(sql(`SELECT count(*) FROM private.operational_incidents WHERE created_by<>'${userId}'`)==='0'){
   await visit('/incidents');await capture('synthetic-incidents.html');await visit(detailPath);
  }
  await page.getByRole('heading',{name:'Synthetic response test',exact:true}).waitFor();
  await page.getByRole('button',{name:'Change phase',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Change phase'});
  await dialog.getByLabel('Internal coordination note',{exact:true}).fill('Synthetic investigation started');await dialog.getByRole('button',{name:'Change phase',exact:true}).click();await dialog.getByRole('button',{name:'Confirm change phase',exact:true}).click();
  await dialog.getByRole('link',{name:'Open saved incident'}).waitFor();
  assert.equal(sql(`SELECT status FROM private.operational_incidents WHERE incident_id='${incident}'`),'investigating');
  await page.keyboard.press('Escape');assert(await page.getByRole('button',{name:'Change phase',exact:true}).evaluate(e=>e===document.activeElement));
  await visit(detailPath);await page.getByRole('button',{name:'Add update',exact:true}).click();const update=page.getByRole('dialog',{name:'Add update'});
  await update.getByLabel('Internal coordination note',{exact:true}).fill('Retain after stale edit');
  const result=await auth.rpc('admin_incident_mutate',{p_operation:randomUUID(),p_incident:incident,p_version:2,p_command:'note',p_payload:{kind:'decision',note:'Concurrent synthetic decision'}});assert.equal(result.error,null);
  await update.getByRole('button',{name:'Add update',exact:true}).click();await update.getByRole('button',{name:'Confirm add update',exact:true}).click();
  await update.getByRole('alert').filter({hasText:'incident changed'}).waitFor();assert.equal(await update.getByLabel('Internal coordination note',{exact:true}).inputValue(),'Retain after stale edit');
  await page.keyboard.press('Escape');
  sql('SELECT private.process_staff_inbox(100)');
  await visit('/inbox?filter=all&category=incidents');assert(await page.locator(`a[href="${detailPath}"]`).count()>0);
  assert(!(await page.locator('.inbox-list').textContent()).includes('Synthetic internal note'));
  assert.equal((await auth.rpc('admin_configure_incident_audience',{p_operation:randomUUID(),p_roles:['super_admin','admin']})).error,null);
  for(const role of STAFF_ROLES){sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);await visit(detailPath);assert.equal(new URL(page.url()).pathname,canAccess(role,detailPath)?detailPath:'/overview');if(canAccess(role,detailPath))assert.equal(await page.locator('.incident-facts').count(),1,'expanded cohort renders real record');}
  sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
  assert.equal((await auth.rpc('admin_configure_incident_audience',{p_operation:randomUUID(),p_roles:['super_admin']})).error,null);
  sql(`UPDATE public.users SET user_role='admin' WHERE user_id='${userId}'`);
  await visit(detailPath);assert.equal(await page.locator('.incident-facts').count(),0,'removed cohort loses browser record access');
  assert.equal((await auth.rpc('admin_staff_inbox_page',{p_category:'incidents'})).data?.length,0,'removed cohort loses previously delivered notices');
  const attention=await auth.rpc('admin_staff_attention');assert(!attention.data?.queues?.some(q=>q.key==='incidents'),'removed cohort loses badge');
  sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
  await page.setViewportSize({width:390,height:844});await visit(detailPath);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'detail fits mobile viewport');
  // Exercise real confirmed forms all the way to immutable review.
  await page.setViewportSize({width:1440,height:1000});
  async function phase(next,{blocked=false}={}){
   await visit(detailPath);await page.getByRole('button',{name:'Change phase',exact:true}).click();
   const d=page.getByRole('dialog',{name:'Change phase'});
   // A wrapping select label includes its option text in the accessible name.
   // Match the named combobox, not an exact bare text label that never exists.
   await d.getByRole('combobox',{name:/^Next phase(?:\s|$)/}).selectOption(next);
   await d.getByLabel('Internal coordination note',{exact:true}).fill(`Synthetic phase ${next}`);
   await d.getByRole('button',{name:'Change phase',exact:true}).click();
   await d.getByRole('button',{name:'Confirm change phase',exact:true}).click();
   if(blocked){
    await d.getByRole('alert').filter({hasText:'open follow-ups'}).waitFor();
    assert.equal(await d.getByLabel('Internal coordination note',{exact:true}).inputValue(),`Synthetic phase ${next}`);
   }else{
    await d.getByRole('link',{name:'Open saved incident'}).waitFor();
    assert.equal(sql(`SELECT status FROM private.operational_incidents WHERE incident_id='${incident}'`),next);
   }
   await page.keyboard.press('Escape');
  }
  await phase('mitigating');await phase('monitoring');await phase('investigating');
  await phase('mitigating');await phase('monitoring');await phase('resolved');
  await visit(detailPath);await page.getByRole('button',{name:'Add follow-up',exact:true}).click();
  const followup=page.getByRole('dialog',{name:'Add follow-up'});
  await followup.getByLabel('Follow-up title',{exact:true}).fill('Synthetic restore drill');
  await followup.getByRole('button',{name:'Find staff',exact:true}).click();
  await followup.getByRole('button',{name:'Console Test',exact:true}).click();
  await followup.getByLabel('Follow-up deadline (UTC)',{exact:true}).fill(new Date(Date.now()+86400000).toISOString().slice(0,16));
  await followup.getByRole('button',{name:'Add follow-up',exact:true}).click();
  await followup.getByRole('button',{name:'Confirm add follow-up',exact:true}).click();
  await followup.getByRole('link',{name:'Open saved incident'}).waitFor();await page.keyboard.press('Escape');
  assert.equal(sql(`SELECT count(*) FROM private.incident_actions WHERE incident_id='${incident}' AND owner_id='${userId}' AND completed_at IS NULL`),'1','selected follow-up owner persisted');
  await phase('reviewed',{blocked:true});
  assert.equal(sql(`SELECT status FROM private.operational_incidents WHERE incident_id='${incident}'`),'resolved','blocked review does not mutate phase');
  await visit(detailPath);await page.getByRole('button',{name:'Complete follow-up',exact:true}).click();
  const completion=page.getByRole('dialog',{name:'Complete follow-up'});
  await completion.getByLabel('Internal coordination note',{exact:true}).fill('Synthetic drill verified');
  await completion.getByRole('button',{name:'Complete follow-up',exact:true}).click();
  await completion.getByRole('button',{name:'Confirm complete follow-up',exact:true}).click();
  await completion.getByRole('link',{name:'Open saved incident'}).waitFor();await page.keyboard.press('Escape');
  await phase('reviewed');await visit(detailPath);
  assert.equal(await page.getByText('Reviewed record · read only',{exact:true}).count(),1);
  assert.equal(await page.getByRole('button',{name:'Change phase',exact:true}).count(),0);
  sql('SELECT private.process_staff_inbox(100)');
  await visit('/incidents?filter=active');
  assert.equal(await page.getByRole('link',{name:'Open response INC-'+sql(`SELECT number FROM private.operational_incidents WHERE incident_id='${incident}'`),exact:true}).count(),0,'reviewed record leaves active queue');
  await visit(detailPath);
  sql(`UPDATE public.users SET account_status='suspended' WHERE user_id='${userId}'`);await visit(detailPath);assert.equal(await page.locator('.incident-facts').count(),0,'suspended staff lose current-record access');
  sql(`UPDATE public.users SET account_status='active' WHERE user_id='${userId}'`);
  assert.equal((await auth.rpc('admin_configure_incidents',{p_operation:randomUUID(),p_enabled:false})).error,null);
  await visit(detailPath);assert.equal(await page.getByRole('heading',{name:'Incident unavailable',exact:true}).count(),1);
  assert.equal(sql(`SELECT count(*) FROM private.operational_incidents WHERE incident_id='${incident}'`),'1','rollback keeps incident');
  assert.equal(errors.length,0);
  console.log('PASS incidents: six roles, real MFA, cohort/badge failures, independent HTTP monitor, full lifecycle/reopen, owned follow-up, blocked review/input retention, immutable review, safe notices, mobile and rollback');
 }finally{
  await context?.close();
  // Only records owned by this disposable Auth fixture are removed. Production
  // incident history is immutable; trigger bypass is local test cleanup only.
  sql(`BEGIN; UPDATE private.incident_control SET enabled=false,notifications_enabled=false,audience_roles=ARRAY[${control.audience_roles.map(r=>`'${r}'`).join(',')}];
   UPDATE private.staff_inbox_control SET enabled=false,audience_roles=ARRAY[${inbox.audience_roles.map(r=>`'${r}'`).join(',')}],worker_at=${inbox.worker_at?`'${inbox.worker_at}'::timestamptz`:'NULL'};
   DELETE FROM private.staff_inbox_deliveries WHERE event_id IN (SELECT event_id FROM private.staff_event_outbox WHERE source_id IN(SELECT incident_id FROM private.operational_incidents WHERE created_by='${userId}'));
   DELETE FROM private.staff_event_outbox WHERE source_id IN(SELECT incident_id FROM private.operational_incidents WHERE created_by='${userId}');
   SET LOCAL session_replication_role=replica;
   DELETE FROM private.incident_events WHERE incident_id IN(SELECT incident_id FROM private.operational_incidents WHERE created_by='${userId}');
   DELETE FROM private.incident_actions WHERE incident_id IN(SELECT incident_id FROM private.operational_incidents WHERE created_by='${userId}');
   DELETE FROM private.operational_incidents WHERE created_by='${userId}';
   SET LOCAL session_replication_role=origin;
   UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
   ${cron.map(c=>`SELECT cron.alter_job(${c.id},active:=${c.active});`).join('\n')} COMMIT;`);
 }
}
