// Production-build browser + real session/RPC tests; disposable local cases only.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { STAFF_ROLES } from '../lib/roles.ts';

export async function checkModerationNotices({browser,cookies,origin,userId,dbUrl,auth}) {
  assert.equal(new URL(dbUrl).hostname,'127.0.0.1');
  const sql=statement=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local moderation notice fixture query failed');}};
  const control=JSON.parse(sql('SELECT row_to_json(c) FROM private.staff_inbox_control c'));
  assert.equal(control.enabled,false,'refuse an enabled pilot');
  const cron=sql("SELECT active FROM cron.job WHERE jobname='staff-inbox-dispatch'");
  const source=randomUUID();let context;
  const command=async(name,args)=>{const result=await auth.rpc(name,args);assert.equal(result.error,null,`${name} must succeed with a real staff session`);};
  // Force both real HTTP calls to wait on the same case. Sequential repeats
  // would miss a stale before-state race in the legacy source RPCs.
  async function concurrentCommand(name,args) {
    const holder=spawn('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1'],{stdio:['pipe','pipe','ignore']});
    const exited=new Promise(resolve=>holder.once('exit',resolve));
    let timer,calls,waiting=0;
    try {
      const ready=new Promise((resolve,reject)=>{
        timer=setTimeout(()=>reject(Error('Local fixture lock timed out')),3000);
        holder.stdout.on('data',chunk=>{if(chunk.toString().includes('fixture-locked'))resolve();});
        holder.once('error',reject);
      });
      holder.stdin.write(`BEGIN; SET LOCAL idle_in_transaction_session_timeout='8s'; SELECT case_id FROM public.moderation_cases WHERE case_id='${source}' FOR UPDATE; SELECT 'fixture-locked';\n`);
      await ready;clearTimeout(timer);
      calls=Promise.all([auth.rpc(name,args),auth.rpc(name,args)]);
      const deadline=Date.now()+2000;
      while(Date.now()<deadline) {
        waiting=Number(sql(`SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%${name}%'`));
        if(waiting>=2)break;
        await new Promise(resolve=>setTimeout(resolve,40));
      }
    } finally {clearTimeout(timer);holder.stdin.end('COMMIT;\n');await exited;}
    const results=await calls;assert(waiting>=2,'both HTTP requests actually contended on the case');
    for(const result of results)assert.equal(result.error,null,'contended command succeeds');
  }
  try {
    sql(`SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname='staff-inbox-dispatch';
      UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      INSERT INTO public.moderation_cases(case_id,target_type,target_id,status,severity) VALUES('${source}','profile','${userId}','open','normal');
      UPDATE private.staff_inbox_control SET enabled=true,moderation_events_enabled=true,delivery_retention_enabled=false,audience_roles=ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor'];`);
    await concurrentCommand('admin_assign_case',{p_case:source,p_assignee:userId,p_reason:'private-browser-sentinel'});
    await command('admin_assign_case',{p_case:source,p_assignee:userId,p_reason:'private-browser-sentinel'});
    assert.equal(sql(`SELECT count(*) FROM private.staff_event_outbox WHERE source_id='${source}'`),'1','duplicate assignment produces one event');
    sql('SELECT private.process_staff_inbox(100)');
    sql('SELECT private.process_staff_inbox(100)');
    assert.equal(sql(`SELECT count(*) FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id) WHERE o.source_id='${source}'`),'1','worker replay never duplicates delivery');
    context=await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'});
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    const page=await context.newPage(),errors=[];page.on('pageerror',()=>errors.push('runtime error'));
    const visit=()=>page.goto(`${origin}/inbox?filter=all&category=moderation`,{waitUntil:'networkidle'});
    const list=page.locator('main .inbox-list');
    for(const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);
      await visit();
      const response=await context.request.get(`${origin}/inbox/data?mode=items&filter=all&category=moderation`);
      assert.equal(response.status(),200);assert.match(response.headers()['cache-control'],/no-store/);
      const body=await response.json(),permitted=['super_admin','admin','moderator'].includes(role);
      assert.equal(body.items.length,permitted?1:0,`${role} source access`);
      assert.equal(await list.locator('.inbox-row').count(),permitted?1:0);
      assert(!JSON.stringify(body).includes('private-browser-sentinel'),'source notes never leave notification API');
      if(permitted) {
        assert.deepEqual(Object.keys(body.items[0]).sort(),['event_id','kind','severity','source_id','destination','delivered_at','read_at'].sort());
        assert.equal(await list.getByRole('link',{name:/Open source/}).getAttribute('href'),`/moderation/cases/${source}`);
      }
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);await visit();
    await list.getByRole('button',{name:'Mark read',exact:true}).click();
    await list.getByRole('button',{name:'Mark unread',exact:true}).waitFor();
    assert.equal(sql(`SELECT status FROM public.moderation_cases WHERE case_id='${source}'`),'in_review','read does not resolve case');
    await list.getByRole('link',{name:/Open source/}).click();await page.waitForURL(`**/moderation/cases/${source}`);
    assert.equal(new URL(page.url()).pathname,`/moderation/cases/${source}`,'destination opens actual authorized dossier');
    await visit();
    const refresh=()=>page.getByRole('button',{name:'Refresh',exact:true}).first().click();
    await command('admin_assign_case',{p_case:source,p_assignee:null,p_reason:'fixture'});
    await refresh();await page.getByText('No notifications in this view',{exact:true}).waitFor();
    await command('admin_assign_case',{p_case:source,p_assignee:userId,p_reason:'fixture'});sql('SELECT private.process_staff_inbox(100)');
    await refresh();await list.locator('.inbox-row').first().waitFor();
    await concurrentCommand('admin_set_case_status',{p_case:source,p_status:'awaiting_second_review',p_note:'private-browser-sentinel'});
    assert.equal(sql(`SELECT count(*) FROM private.staff_event_outbox WHERE source_id='${source}' AND kind='moderation_review_requested'`),'1','contended review request produces one event');
    sql('SELECT private.process_staff_inbox(100)');
    const independent=await context.request.get(`${origin}/inbox/data?mode=items&filter=all&category=moderation`);
    assert((await independent.json()).items.every(item=>item.kind!=='moderation_review_requested'),'requester is excluded from independent review');
    sql(`UPDATE public.users SET user_role='analyst' WHERE user_id='${userId}'`);
    await refresh();await page.getByText('No notifications in this view',{exact:true}).waitFor();
    sql(`UPDATE public.users SET user_role='super_admin',account_status='suspended' WHERE user_id='${userId}'`);
    assert.notEqual((await context.request.get(`${origin}/inbox/data?mode=items&category=moderation`)).status(),200,'suspension takes effect with existing cookie');
    sql(`UPDATE public.users SET account_status='active' WHERE user_id='${userId}'; UPDATE private.staff_inbox_control SET moderation_events_enabled=false`);
    await visit();assert.equal(await list.locator('.inbox-row').count(),0,'source rollback hides already delivered notices');
    assert.equal(errors.length,0);
    console.log('PASS moderation notices: canonical real-session producers, forced two-request contention, duplicate delivery, six roles, safe metadata, exact dossier link, read/source separation, reassignment, requester exclusion, revocation and source rollback');
  } finally {
    await context?.close();
    // Only this generated local case and its deliveries are removed. Disabling
    // append-only triggers is restricted to this disposable fixture cleanup.
    sql(`BEGIN; UPDATE private.staff_inbox_control SET enabled=false;
      DELETE FROM private.staff_inbox_deliveries WHERE event_id IN(SELECT event_id FROM private.staff_event_outbox WHERE source_id='${source}');
      DELETE FROM private.staff_event_outbox WHERE source_id='${source}';
      SET LOCAL session_replication_role=replica;
      DELETE FROM public.moderation_case_events WHERE case_id='${source}';
      DELETE FROM public.moderation_cases WHERE case_id='${source}';
      SET LOCAL session_replication_role=origin;
      UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      UPDATE private.staff_inbox_control SET moderation_events_enabled=${control.moderation_events_enabled},delivery_retention_enabled=${control.delivery_retention_enabled},audience_roles=ARRAY[${control.audience_roles.map(r=>`'${r}'`).join(',')}],worker_at=${control.worker_at?`'${control.worker_at}'::timestamptz`:'NULL'};
      SELECT cron.alter_job(jobid,active:=${cron==='t'}) FROM cron.job WHERE jobname='staff-inbox-dispatch';COMMIT;`);
  }
}
