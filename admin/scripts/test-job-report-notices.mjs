import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID,createHmac } from 'node:crypto';
import { STAFF_ROLES } from '../lib/roles.ts';
function totp(secret){
  const bits=[...secret.replace(/=+$/,'').toUpperCase()].map(c=>'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5,'0')).join('');
  const key=Buffer.from(bits.match(/.{8}/g).map(b=>parseInt(b,2))),counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));
  const hash=createHmac('sha1',key).update(counter).digest(),offset=hash.at(-1)&15;return String((hash.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0');
}
export async function checkJobReportNotices({browser,cookies,origin,userId,dbUrl,auth}) {
  assert.equal(new URL(dbUrl).hostname,'127.0.0.1');
  const sql=statement=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local job/report fixture query failed');}};
  const control=JSON.parse(sql('SELECT row_to_json(c) FROM private.staff_inbox_control c'));
  assert.equal(control.enabled,false,'refuse active pilot');
  const cron=JSON.parse(sql("SELECT json_agg(json_build_object('id',jobid,'active',active)) FROM cron.job WHERE jobname IN ('staff-inbox-dispatch','staff-inbox-job-attention')"));
  const previous=sql('SELECT coalesce(json_agg(s),\'[]\') FROM private.staff_job_attention s');
  const existing=JSON.parse(sql("SELECT coalesce(json_agg(event_id),'[]') FROM private.staff_event_outbox WHERE kind LIKE 'job_%'"));
  const fixture=randomUUID();let report,context;
  try {
    sql(`SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname IN ('staff-inbox-dispatch','staff-inbox-job-attention');
      UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor'];
      INSERT INTO public.push_delivery_outbox(event_key,user_id,event_kind,status,last_error_code) VALUES('browser-job-${fixture}','${userId}','notification','dead','private-sentinel@example.test');
      INSERT INTO public.email_outbox(outbox_id,user_id,template,status,last_error) VALUES('${fixture}','${userId}','welcome','failed','private-sentinel@example.test');
      INSERT INTO public.media_scan_jobs(kind,content_id,user_id,lease_id,lease_expires_at) VALUES('post','${fixture}','${userId}',gen_random_uuid(),now()-interval '16 minutes');`);
    const factor=await auth.auth.mfa.enroll({factorType:'totp',friendlyName:'Disposable job/report fixture'});assert.equal(factor.error,null);
    const verified=await auth.auth.mfa.challengeAndVerify({factorId:factor.data.id,code:totp(factor.data.totp.secret)});assert.equal(verified.error,null);
    const enabled=await auth.rpc('admin_configure_staff_inbox_sources',{p_operation:randomUUID(),p_jobs:true,p_reports:true});assert.equal(enabled.error,null);
    const reportRequest={p_operation:randomUUID(),p_report_kind:'monthly_impact',p_title:'Synthetic browser report',p_audience:'internal',p_window_start:'2026-01-01',p_window_end:'2026-01-31'};
    const generated=await auth.rpc('admin_generate_impact_report_checked',reportRequest);
    assert.equal(generated.error,null);report=generated.data;assert.match(report,/^[a-f0-9-]{36}$/);
    const repeats=await Promise.all([auth.rpc('admin_generate_impact_report_checked',reportRequest),auth.rpc('admin_generate_impact_report_checked',reportRequest)]);
    for(const repeat of repeats){assert.equal(repeat.error,null);assert.equal(repeat.data,report);}
    sql('SELECT private.refresh_staff_job_attention(); SELECT private.process_staff_inbox(100); SELECT private.refresh_staff_job_attention(); SELECT private.process_staff_inbox(100);');
    context=await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'});
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    const page=await context.newPage(),errors=[];page.on('pageerror',()=>errors.push('runtime error'));
    const list=page.locator('main .inbox-list');
    const items=async category=>{const r=await context.request.get(`${origin}/inbox/data?mode=items&filter=all&category=${category}`);assert.equal(r.status(),200);assert.match(r.headers()['cache-control'],/no-store/);return (await r.json()).items;};
    for(const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);
      await page.goto(`${origin}/inbox?filter=all&category=jobs`,{waitUntil:'networkidle'});
      const jobs=await items('jobs'),reports=await items('reports');
      assert.equal(jobs.length,['super_admin','admin'].includes(role)?3:0,`${role} job notices`);
      assert.equal(reports.length,['super_admin','admin','analyst','read_only_auditor'].includes(role)?1:0,`${role} requester report access`);
      assert(!JSON.stringify({jobs,reports}).includes('private-sentinel'),'provider errors excluded');
      assert(!JSON.stringify(reports).includes('Synthetic browser report'),'report title excluded');
      assert.equal(await list.locator('.inbox-row').count(),jobs.length);
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
    await page.goto(`${origin}/jobs`,{waitUntil:'networkidle'});
    const expectedCount=Number(sql('SELECT least(sum(observed_count),100) FROM private.staff_job_attention'));
    const expectedBadge=expectedCount>99?'99+':String(expectedCount);
    assert.equal(await page.locator('[data-queue-value=jobs]').textContent(),expectedBadge,'page KPI and badge use shared jobs count');
    assert.equal(await page.locator('aside a[href="/jobs"] .inbox-queue-badge').textContent(),expectedBadge);
    assert(!await page.locator('main').textContent().then(text=>text.includes('private-sentinel')),'Jobs never prints raw provider errors');
    await page.goto(`${origin}/inbox?filter=all&category=jobs`,{waitUntil:'networkidle'});
    assert.equal(await list.locator('a[href="/jobs#push-failures"]').count(),1);
    await list.locator('a[href="/jobs#push-failures"]').click();await page.waitForURL('**/jobs#push-failures');await page.locator('#push-failures').waitFor();
    await page.goto(`${origin}/inbox?filter=all&category=reports`,{waitUntil:'networkidle'});
    await list.getByRole('button',{name:'Mark read',exact:true}).click();await list.getByRole('button',{name:'Mark unread',exact:true}).waitFor();
    assert.equal(sql(`SELECT status FROM private.impact_report_snapshots WHERE report_id='${report}'`),'generated');
    await list.getByRole('link',{name:/Open source/}).click();await page.waitForURL(`**/impact/reports/${report}`);
    await page.goto(`${origin}/inbox/operations`,{waitUntil:'networkidle'});
    assert.match(await page.locator('[data-notification-history]').textContent(),/Recorded batches/);
    const response=await context.request.get(`${origin}/inbox/operations/data`),body=await response.json();
    assert(body.observability.hours.length>0);assert(body.observability.hours.length<=24);
    await page.route('**/inbox/operations/data*',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({...body,observability:null})}));
    await page.getByRole('button',{name:'Refresh recovery',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('[data-notification-history]')?.textContent.includes('unavailable'));
    assert.equal(await page.locator('.recovery-metric strong').nth(3).textContent(),'Enabled','history failure does not fabricate processing failure');
    await page.unroute('**/inbox/operations/data*');
    const rollback=await auth.rpc('admin_configure_staff_inbox_sources',{p_operation:randomUUID(),p_jobs:false,p_reports:false});assert.equal(rollback.error,null);
    assert.equal((await items('jobs')).length,0);assert.equal((await items('reports')).length,0);
    assert.equal(errors.length,0);
    console.log('PASS job/report notices: real MFA configuration and report generation, grouped reconciliation, six-role access, shared Jobs KPI/badge, exact links, safe copy, read/source separation, history partial failure and rollback');
  } finally {
    await context?.close();
    const keep=existing.length?`AND event_id NOT IN (${existing.map(id=>`'${id}'`).join(',')})`:'';
    sql(`BEGIN; UPDATE private.staff_inbox_control SET enabled=false;
      DELETE FROM private.staff_inbox_deliveries WHERE event_id IN(SELECT event_id FROM private.staff_event_outbox WHERE (kind LIKE 'job_%' ${keep}) ${report?`OR source_id='${report}'`:''});
      DELETE FROM private.staff_event_outbox WHERE (kind LIKE 'job_%' ${keep}) ${report?`OR source_id='${report}'`:''};
      DELETE FROM public.push_delivery_outbox WHERE event_key='browser-job-${fixture}';
      DELETE FROM public.email_outbox WHERE outbox_id='${fixture}';DELETE FROM public.media_scan_jobs WHERE kind='post' AND content_id='${fixture}';
      SET LOCAL session_replication_role=replica;
      ${report?`DELETE FROM private.impact_report_values WHERE report_id='${report}';DELETE FROM private.impact_report_snapshots WHERE report_id='${report}';`:''}
      SET LOCAL session_replication_role=origin;
      UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      UPDATE private.staff_job_attention s SET observed_count=p.observed_count,has_more=p.has_more,measured_at=p.measured_at FROM json_populate_recordset(NULL::private.staff_job_attention,'${previous.replaceAll("'","''")}')p WHERE s.source_id=p.source_id;
      UPDATE private.staff_inbox_control SET job_events_enabled=${control.job_events_enabled},report_events_enabled=${control.report_events_enabled},audience_roles=ARRAY[${control.audience_roles.map(r=>`'${r}'`).join(',')}],worker_at=${control.worker_at?`'${control.worker_at}'::timestamptz`:'NULL'};
      ${cron.map(c=>`SELECT cron.alter_job(${c.id},active:=${c.active});`).join('\n')} COMMIT;`);
  }
}
