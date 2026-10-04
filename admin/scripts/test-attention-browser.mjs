import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { STAFF_ROLES } from '../lib/roles.ts';
import { queueDestinations } from '../lib/inbox-model.ts';
import { syntheticShell } from './synthetic-shell.mjs';

export async function checkAttentionBrowser({browser,cookies,origin,userId,dbUrl,outputDir}) {
  assert.equal(new URL(dbUrl).hostname,'127.0.0.1');
  assert(/^[a-f0-9-]{36}$/.test(userId));
  const sql=statement=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local attention fixture query failed');}};
  const control=JSON.parse(sql('SELECT row_to_json(c) FROM private.staff_inbox_control c'));
  assert.equal(control.enabled,false,'refuse enabled local pilot');
  const saved=JSON.parse(sql("SELECT coalesce(jsonb_agg(to_jsonb(s)),'[]') FROM private.staff_attention_snapshots s"));
  const changes=JSON.parse(sql("SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]') FROM private.staff_attention_changes c"));
  const cron=sql("SELECT active FROM cron.job WHERE jobname='staff-inbox-dispatch'");
  const support=randomUUID();let context;
  const literal=v=>`'${JSON.stringify(v).replaceAll("'","''")}'::jsonb`;
  try {
    sql("SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname='staff-inbox-dispatch'");
    sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      INSERT INTO private.support_cases(support_case_id,source_kind,category,status,sla_due_at,created_by)
      VALUES('${support}','other','technical','open',now()+interval '1 day','${userId}');
      UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor'],worker_at=now();
      SELECT private.refresh_staff_attention();`);
    context=await browser.newContext({viewport:{width:1440,height:1100},reducedMotion:'reduce'});
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    const page=await context.newPage();const errors=[];page.on('pageerror',()=>errors.push('page error'));
    const visit=path=>page.goto(`${origin}${path}`,{waitUntil:'networkidle'});
    const refresh=async()=>{
      const response=page.waitForResponse(r=>r.url().includes('/inbox/data?mode=attention'));
      await page.getByRole('button',{name:'Refresh counts',exact:true}).click();await response;
      await page.waitForFunction(()=>!document.querySelector('[data-attention-panel]')?.textContent.includes('Checking counts…'));
    };
    for(const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);
      await visit('/overview');
      const response=await context.request.get(`${origin}/inbox/data?mode=attention`);
      assert.equal(response.status(),200);const data=await response.json();
      const expected={super_admin:4,admin:3,moderator:2,support:1,analyst:0,read_only_auditor:0}[role];
      assert.equal(data.queues.length,expected);
      assert.equal(await page.locator('[data-queue-value]').count(),expected);
      for(const q of data.queues) {
        assert.equal(await page.locator(`[data-queue-value="${q.key}"]`).innerText(),q.count.toLocaleString('en-US'));
        const badge=page.locator('aside').getByLabel(`${q.count>99?'99+':q.count} ${queueDestinations[q.key].label.toLowerCase()}`,{exact:true});
        assert.equal(await badge.innerText(),q.count>99?'99+':String(q.count));
        assert.equal(await badge.locator('..').getAttribute('href'),queueDestinations[q.key].href);
      }
      // Turning off the inbox UI doesn't leak lists or disable queue counts.
      assert.deepEqual(await (await context.request.get(`${origin}/inbox/data?mode=items`)).json(),{enabled:false});
      assert(await page.getByRole('button',{name:'Staff inbox is not enabled',exact:true}).isDisabled());
      console.log(`PASS shared attention role and badge parity: ${role}`);
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
    for(const[key,d]of Object.entries(queueDestinations)) {
      await visit(d.href);
      const data=await (await context.request.get(`${origin}/inbox/data?mode=attention`)).json();
      if(key==='jobs'||key==='incidents') {
        // Jobs has an independent producer switch and incidents a server-side
        // pilot audience, both intentionally off here. Enabled-state parity is
        // covered by test-job-report-notices and test-incident-browser.
        assert(!data.queues.some(q=>q.key===key));
        assert.equal(await page.locator(`[data-attention-panel="${key}"]`).count(),0,`disabled ${key} source must not invent an actionable KPI`);
        assert.equal(await page.locator(`aside a[href="${d.path}"] .inbox-queue-badge`).count(),0);
      } else {
        await page.locator(`[data-attention-panel="${key}"]`).waitFor();
        assert.equal(await page.locator(`[data-queue-value="${key}"]`).innerText(),data.queues.find(q=>q.key===key).count.toLocaleString('en-US'));
      }
    }
    // Source mutation invalidates immediately, then reconciles without inventing
    // a decrement from the notification read state.
    await visit('/support/cases?queue=open');
    const before=Number(sql("SELECT open_count FROM private.staff_attention_snapshots WHERE queue_key='support'"));
    sql(`UPDATE private.support_cases SET status='resolved',resolved_at=now() WHERE support_case_id='${support}'`);
    await refresh();assert.equal(await page.locator('[data-queue-value="support"]').innerText(),'—');
    sql('SELECT private.refresh_staff_attention()');await refresh();
    assert.equal(await page.locator('[data-queue-value="support"]').innerText(),(before-1).toLocaleString('en-US'));

    // Two real connections: worker holds its projection update open. Source
    // writes must complete WITHOUT waiting for the worker transaction to end.
    const child=spawn('psql',[dbUrl,'-X','-qAt','-v','ON_ERROR_STOP=1'],{stdio:['pipe','pipe','pipe']});
    child.stderr.resume();
    const done=new Promise((res,rej)=>{child.on('error',rej);child.on('exit',code=>code===0?res():rej(Error('concurrency fixture failed')));});
    const locked=new Promise(res=>child.stdout.on('data',b=>{if(b.toString().includes('locked'))res();}));
    child.stdin.write("BEGIN; SELECT private.refresh_staff_attention(); SELECT 'locked';\n");
    await locked;
    try { sql(`SET statement_timeout='1500ms'; UPDATE private.support_cases SET status='open',resolved_at=NULL WHERE support_case_id='${support}'`); }
    finally { child.stdin.end('COMMIT;\n');await done; }
    assert.equal(sql("SELECT EXISTS(SELECT 1 FROM private.staff_attention_changes WHERE queue_key='support')"),'t');
    sql('SELECT private.refresh_staff_attention()');await refresh();

    await page.route('**/inbox/data?mode=attention',route=>route.fulfill({status:503,body:'{}',contentType:'application/json'}));
    await refresh();await page.getByText('Counts unavailable. Check your connection or session, then retry.',{exact:true}).waitFor();
    assert.equal(await page.locator('[data-queue-value]').count(),0);
    await page.unroute('**/inbox/data?mode=attention');await refresh();await page.locator('[data-queue-value="support"]').waitFor();
    await page.route('**/inbox/data?mode=attention',route=>route.fulfill({status:200,body:'{"enabled":true,"queues":[{"key":"private-evidence"}]}',contentType:'application/json'}));
    await refresh();assert.equal(await page.locator('[data-queue-value]').count(),0);await page.unroute('**/inbox/data?mode=attention');await refresh();
    sql("UPDATE private.staff_attention_snapshots SET measured_at=now()-interval '3 minutes' WHERE queue_key='support'");
    await refresh();assert.equal(await page.locator('[data-queue-value="support"]').innerText(),'—');sql('SELECT private.refresh_staff_attention()');await refresh();

    sql('UPDATE private.staff_inbox_control SET worker_at=now()');
    let reads=0;page.on('request',r=>{if(r.url().includes('/inbox/data?mode=attention'))reads++;});
    await page.waitForTimeout(31_000);assert(reads>=1,'visible polling');
    await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'));});
    const hidden=reads;await page.waitForTimeout(31_000);assert.equal(reads,hidden,'background paused');
    await page.evaluate(()=>{delete document.hidden;window.dispatchEvent(new Event('focus'));});await page.waitForTimeout(1000);assert(reads>hidden,'focus refresh');
    sql(`UPDATE public.users SET user_role='analyst' WHERE user_id='${userId}'`);await refresh();assert.equal(await page.locator('[data-attention-panel]').count(),0,'revoked queue disappears without login');
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);await visit('/overview');
    sql('UPDATE private.staff_inbox_control SET enabled=false');await refresh();await page.getByText('Attention pilot is not enabled for this account. Use the source queues.',{exact:true}).waitFor();
    sql('UPDATE private.staff_inbox_control SET enabled=true,worker_at=now()');sql('SELECT private.refresh_staff_attention()');await refresh();

    // Reconstruct from sanitized current chrome, with all counts overwritten
    // to fictional values. A fresh checkout needs no prior run's HTML files.
    const fragment=await page.locator('[data-attention-panel="all"]').evaluate(el=>{
      const copy=el.cloneNode(true);copy.querySelectorAll('[data-queue-value]').forEach((n,i)=>n.textContent=String([8,3,24,12][i]));
      copy.querySelectorAll('time').forEach(n=>{n.textContent='2026-09-25 10:30 UTC';n.setAttribute('datetime','2026-09-25T10:30:00Z');});
      return copy.outerHTML;
    });
    const synthetic=await syntheticShell(page);
    const css=await page.evaluate(()=>[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules].map(r=>r.cssText);}catch{return [];}}).join('\n'));
    await page.setContent(synthetic);await page.evaluate(({fragment,css})=>{
      document.querySelector('.operator-queue-panel').outerHTML=fragment;
      document.querySelector('style').textContent=css;
      document.querySelectorAll('a').forEach(n=>n.setAttribute('href','#'));
      document.querySelectorAll('script').forEach(n=>n.remove());
    },{fragment,css});
    const html=await page.content();await writeFile(resolve(outputDir,'synthetic-attention.html'),html);
    await page.screenshot({path:resolve(outputDir,'synthetic-attention.png'),fullPage:true});
    await page.setViewportSize({width:390,height:844});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
    await page.screenshot({path:resolve(outputDir,'synthetic-attention-mobile.png'),fullPage:true});
    await page.setViewportSize({width:1440,height:1100});
    sql(`UPDATE public.users SET account_status='suspended' WHERE user_id='${userId}'`);
    assert.equal((await context.request.get(`${origin}/inbox/data?mode=attention`)).status(),403);
    assert.equal(errors.length,0);
    console.log('PASS shared page parity, invalidation/reconciliation, concurrent write, malformed/failed/stale states, polling/focus, revocation and rollback');
  }finally{
    await context?.close();
    sql(`UPDATE private.staff_inbox_control SET enabled=false; DELETE FROM private.support_cases WHERE support_case_id='${support}';
      UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      DELETE FROM private.staff_attention_changes;`);
    for(const row of changes)sql(`INSERT INTO private.staff_attention_changes SELECT * FROM jsonb_populate_record(NULL::private.staff_attention_changes,${literal(row)})`);
    for(const row of saved)sql(`INSERT INTO private.staff_attention_snapshots SELECT * FROM jsonb_populate_record(NULL::private.staff_attention_snapshots,${literal(row)}) ON CONFLICT(queue_key) DO UPDATE SET open_count=EXCLUDED.open_count,measured_at=EXCLUDED.measured_at,invalidated=EXCLUDED.invalidated`);
    sql(`UPDATE private.staff_inbox_control SET audience_roles=ARRAY[${control.audience_roles.map(r=>`'${r}'`).join(',')}],worker_at=${control.worker_at?`'${control.worker_at}'::timestamptz`:'NULL'};
      SELECT cron.alter_job(jobid,active:=${cron==='t'}) FROM cron.job WHERE jobname='staff-inbox-dispatch';`);
  }
}
