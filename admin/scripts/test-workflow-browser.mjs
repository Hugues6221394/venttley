import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHmac,randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import {checkWorkflowCommands} from './test-workflow-commands.mjs';
import { STAFF_ROLES,canAccess } from '../lib/roles.ts';
import { syntheticShell } from './synthetic-shell.mjs';

// TOTP is generated only for the disposable local fixture. No token, QR code,
// secret, request body or actual member content is written to artifacts/logs.
function totp(secret) {
  const bits=[...secret.replace(/=+$/,'').toUpperCase()].map(c=>'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5,'0')).join('');
  const key=Buffer.from(bits.match(/.{8}/g).map(b=>parseInt(b,2)));
  const counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));
  const hash=createHmac('sha1',key).update(counter).digest(),offset=hash.at(-1)&15;
  return String((hash.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0');
}

export async function checkWorkflowBrowser({browser,cookies,origin,userId,dbUrl,outputDir,auth,proxy}) {
  assert.equal(new URL(dbUrl).hostname,'127.0.0.1');assert(/^[a-f0-9-]{36}$/.test(userId));
  const sql=statement=>{try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}catch{throw Error('Local workflow fixture query failed');}};
  const ids=Array.from({length:31},()=>randomUUID());const chosen=ids[0];let context;
  try {
    assert.equal(sql('SELECT enabled FROM private.staff_inbox_control'),'f','local notification pilot must stay disabled');
    sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      INSERT INTO private.support_cases(support_case_id,source_kind,category,status,sla_due_at,created_by,assigned_to)
      VALUES ${ids.map((id,i)=>`('${id}','other','technical','open','2000-01-01T00:${String(i).padStart(2,'0')}:00Z','${userId}','${userId}')`).join(',')}`);
    context=await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'});
    const applyCookies=()=>context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    await applyCookies();const page=await context.newPage(),errors=[];page.on('pageerror',()=>errors.push('page error'));
    const visit=path=>page.goto(`${origin}${path}`,{waitUntil:'networkidle',timeout:60000});
    for(const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);
      for(const path of ['/moderation','/appeals','/safety','/support/cases']) {
        await visit(path);
        assert.equal(new URL(page.url()).pathname,canAccess(role,path)?path:'/overview',`${role} direct ${path}`);
        if(canAccess(role,path))assert.equal(await page.locator('.operator-page').count(),1);
      }
      console.log(`PASS daily workflow direct URLs: ${role}`);
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
    await visit('/support/cases?owner=mine');
    await page.getByRole('link',{name:'Next page',exact:true}).click();
    await page.waitForURL(/afterId=/);const cursor=new URL(page.url()).searchParams.get('afterId');
    await page.getByRole('link',{name:'Open case',exact:true}).first().click();
    await page.getByRole('button',{name:'Edit case',exact:true}).waitFor();
    assert.equal(new URL(page.url()).searchParams.get('afterId'),cursor,'opening a case preserves pagination');
    await page.getByRole('link',{name:'First page',exact:true}).click();await page.waitForURL(url=>!url.searchParams.has('afterId'));
    const selected=`/support/cases?queue=open&owner=mine&source=${chosen}`;
    const openEdit=async()=>{await visit(selected);await page.getByRole('button',{name:'Edit case',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Update support case'});await dialog.waitFor();return dialog;};
    const save=async dialog=>{await dialog.getByRole('button',{name:'Save case',exact:true}).click();await dialog.getByRole('button',{name:'Confirm save case',exact:true}).click();};
    let dialog=await openEdit();await dialog.locator('select[name="priority"]').selectOption('high');await save(dialog);
    await dialog.getByRole('alert').filter({hasText:'Complete MFA'}).waitFor();
    assert.equal(await dialog.locator('select[name="priority"]').inputValue(),'high','failed save retains input');
    assert.equal(sql(`SELECT priority FROM private.support_cases WHERE support_case_id='${chosen}'`),'normal','AAL1 cannot mutate');
    await page.keyboard.press('Escape');assert(await page.getByRole('button',{name:'Edit case',exact:true}).evaluate(n=>n===document.activeElement));
    const factor=await auth.auth.mfa.enroll({factorType:'totp',friendlyName:'Disposable workflow browser fixture'});
    assert.equal(factor.error,null,'local MFA enrollment');
    const verified=await auth.auth.mfa.challengeAndVerify({factorId:factor.data.id,code:totp(factor.data.totp.secret)});
    assert.equal(verified.error,null,'real local MFA challenge');await applyCookies();
    dialog=await openEdit();await dialog.locator('select[name="priority"]').selectOption('high');
    proxy.control.mode='slow';await save(dialog);await page.keyboard.press('Escape');assert(await dialog.isVisible(),'pending request cannot be dismissed');
    await dialog.getByRole('status').filter({hasText:'Support case updated.'}).waitFor();proxy.control.mode='normal';
    assert.equal(sql(`SELECT priority FROM private.support_cases WHERE support_case_id='${chosen}'`),'high');
    console.log('PASS real MFA rejection/success, input retention and pending drawer protection');
    dialog=await openEdit();await dialog.locator('select[name="priority"]').selectOption('critical');
    sql(`UPDATE private.support_cases SET updated_at=now()+interval '1 second' WHERE support_case_id='${chosen}'`);
    const conflict=await auth.rpc('admin_update_support_case_checked',{p_operation:randomUUID(),p_case:chosen,p_status:'open',p_priority:'critical',p_assignee:userId,p_expected_updated_at:await dialog.locator('input[name="expected_updated_at"]').inputValue()});
    assert.match(conflict.error?.message??'',/workflow_conflict/,'real authenticated API must preserve conflict classification');
    assert.equal(conflict.status,409,'business conflict is not a transient server failure');
    await save(dialog);await dialog.locator('.workflow-result').waitFor();
    assert.match(await dialog.locator('.workflow-result p').first().innerText(),/changed since you opened/,'stale save returns actionable conflict feedback');
    assert.equal(await dialog.locator('select[name="priority"]').inputValue(),'critical');
    assert.equal(sql(`SELECT priority FROM private.support_cases WHERE support_case_id='${chosen}'`),'high','stale save has no partial effect');
    dialog=await openEdit();await dialog.locator('select[name="priority"]').selectOption('low');
    sql(`UPDATE public.users SET user_role='analyst' WHERE user_id='${userId}'`);
    await save(dialog);
    await page.waitForFunction(()=>location.pathname==='/overview'||document.querySelector('.workflow-result'));
    if(new URL(page.url()).pathname==='/overview')assert.equal(await page.locator('.workflow-form').count(),0,'revocation discards inaccessible forms');
    else {
      assert.equal(await dialog.locator('select[name="priority"]').inputValue(),'low','failed action retains inputs');
      assert.equal(await dialog.locator('.workflow-result.is-success').count(),0,'denied action never reports success');
    }
    assert.equal(sql(`SELECT priority FROM private.support_cases WHERE support_case_id='${chosen}'`),'high');
    await visit(selected);assert.equal(new URL(page.url()).pathname,'/overview','fresh navigation removes revoked workflow');
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
    proxy.control.mode='failed';await visit('/support/cases');await page.getByRole('heading',{name:'Queue unavailable'}).waitFor();
    assert.equal(await page.getByText('No cases in this view.',{exact:true}).count(),0);proxy.control.mode='normal';
    await visit('/support/cases');await page.getByRole('heading',{name:'Case queue',exact:true}).waitFor();
    console.log('PASS cursor navigation, stale edit rejection, live permission loss and unavailable queue');

    await checkWorkflowCommands({page,visit,sql,userId,auth});

    // All subsequent queue responses are explicitly fictional. The capture
    // includes only this main region plus sanitized current shared chrome.
    const fake='1a620000-1000-4000-8000-000000000001',date='2026-09-25T10:30:00Z';
    const support={support_case_id:fake,source_kind:'other',source_id:null,member_id:null,category:'technical',status:'open',priority:'high',assignee_id:null,assignee_name:null,sla_due_at:date,first_response_at:null,resolved_at:null,created_at:date,updated_at:date};
    const moderation={case_id:fake,target_type:'post',target_id:fake,subject_id:fake,subject_pseudonym:'synthetic_member',status:'open',severity:'high',assignee_id:null,assignee_pseudonym:null,report_count:3,evidence:null,sla_due_at:date,sla_breached:false,minutes_to_due:60,legal_hold:false,opened_at:date,updated_at:date};
    proxy.control.fixtures={admin_support_work_queue:[support],admin_support_case_queue_filtered:[support],admin_support_assignees:[{staff_id:fake,display_name:'Sample Operator',username:'sample_operator'}],
      admin_case_work_queue:[moderation],admin_appeal_work_queue:[{appeal_id:fake,case_id:fake,subject_kind:'case',appellant_id:fake,appellant_pseudonym:'synthetic_member',statement:'Fictional statement for interface testing.',status:'open',original_decision:'content_removed',original_note:'Fictional decision reason.',original_decider_pseudonym:'sample_operator',reviewable_by_me:true,created_at:date}],
      admin_safety_work_queue:[{item_type:'crisis_post',severity:'high',severity_rank:1,ref_id:fake,report_id:null,note:null,preview:'Fictional signal for interface testing only.',is_open:true,created_at:date}]};
    proxy.control.fixtures.admin_support_history=[{event_id:fake,event_kind:'opened',actor_name:'Sample Operator',from_status:null,to_status:'open',priority:'high',assigned:false,created_at:date}];
    proxy.control.mode='synthetic';
    const shell=await syntheticShell(page);
    const capture=async name=>{
      const content=await page.locator('main').evaluate(n=>{
        const copy=n.cloneNode(true);
        const actual=n.querySelectorAll('select'),clones=copy.querySelectorAll('select');
        actual.forEach((s,i)=>[...clones[i].options].forEach(o=>o.toggleAttribute('selected',o.value===s.value)));
        return copy.innerHTML;
      });
      const breadcrumb=await page.locator('.operator-breadcrumb').innerHTML();
      const navigation=await page.locator('aside').evaluate(n=>{
        const copy=n.cloneNode(true);
        copy.querySelectorAll('.operator-page-link').forEach(a=>[...a.children].slice(1).forEach(c=>c.remove()));
        copy.querySelectorAll('script').forEach(n=>n.remove());
        return copy.innerHTML;
      });
      const css=await page.evaluate(()=>[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules].map(r=>r.cssText);}catch{return [];}}).join('\n'));
      const preview=await context.newPage();await preview.setContent(shell.replace('<head>',`<head><base href="${origin}">`));await preview.evaluate(({content,css,breadcrumb,navigation})=>{
        document.querySelector('main').innerHTML=content;document.querySelector('style').textContent=css;
        document.querySelector('.operator-breadcrumb').innerHTML=breadcrumb;document.querySelector('aside').innerHTML=navigation;
        document.querySelectorAll('script').forEach(n=>n.remove());document.querySelectorAll('a').forEach(n=>n.setAttribute('href','#'));
        document.querySelectorAll('input[type=hidden]').forEach(n=>n.remove());
        const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while((node=walker.nextNode()))node.textContent=node.textContent.replace(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/gi,'synthetic-id');
        document.querySelectorAll('dialog[open]').forEach(n=>{n.removeAttribute('open');n.showModal();});
      },{content,css,breadcrumb,navigation});
      await preview.locator('img').evaluateAll(images=>Promise.all(images.map(img=>img.decode().catch(()=>{}))));
      await writeFile(resolve(outputDir,`synthetic-${name}.html`),(await preview.content()).replace(/<base[^>]+>/,''));
      await preview.screenshot({path:resolve(outputDir,`synthetic-${name}.png`),fullPage:true});
      await preview.setViewportSize({width:390,height:844});
      assert(await preview.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`${name} viewport does not overflow`);
      await preview.screenshot({path:resolve(outputDir,`synthetic-${name}-mobile.png`),fullPage:true});await preview.close();
    };
    for(const [path,title,name,trigger]of [
      ['/moderation','Moderation queue','moderation','Review case'],
      ['/appeals','Appeals review','appeals','Review appeal'],
      ['/safety','Safety & crisis','safety','View signal'],
      [`/support/cases?source=${fake}`,'Support cases','support','Edit case'],
    ]) {
      await visit(path);await page.getByRole('heading',{name:title,exact:true}).waitFor();await capture(name);
      await page.getByRole('button',{name:trigger,exact:true}).click();await page.getByRole('dialog').waitFor();
      await page.keyboard.press('Shift+Tab');assert(await page.getByRole('dialog').evaluate(d=>d.contains(document.activeElement)),'focus contained');
      if(name==='support') {
        const owner=page.getByRole('dialog').getByLabel('Owner',{exact:true});await owner.selectOption(fake);
        proxy.control.fixtures.admin_support_assignees=[];
        await page.getByRole('dialog').getByRole('button',{name:'Search staff',exact:true}).click();
        await page.getByRole('dialog').getByRole('button',{name:'Search staff',exact:true}).waitFor();
        assert.equal(await owner.inputValue(),fake,'selected owner survives a search with no results');await capture('support-detail');
      }
      await page.setViewportSize({width:390,height:844});assert(await page.getByRole('dialog').evaluate(d=>d.getBoundingClientRect().right<=innerWidth+1));
      await page.keyboard.press('Escape');assert(await page.getByRole('button',{name:trigger,exact:true}).evaluate(n=>n===document.activeElement));await page.setViewportSize({width:1440,height:1000});
    }
    sql(`UPDATE public.users SET user_role='support' WHERE user_id='${userId}'`);await visit('/safety');await page.getByRole('button',{name:'View signal',exact:true}).click();assert.equal(await page.locator('.workflow-form').count(),0,'support cannot clear crisis flags');
    proxy.control.mode='normal';sql(`UPDATE public.users SET account_status='suspended' WHERE user_id='${userId}'`);
    const denied=await auth.rpc('admin_support_work_queue');assert(denied.error,'suspended current JWT denied by database');await visit('/support/cases');assert.equal(await page.locator('.workflow-form').count(),0);
    assert.equal(errors.length,0,'no browser runtime exceptions');
    console.log('PASS synthetic queue/drawer rendering, mobile, keyboard, selected owner persistence and suspended access');
  }finally{
    proxy.control.mode='normal';await context?.close();
    // Disposable LOCAL fixtures only. Session-local replica mode permits exact
    // fixture cleanup without disabling a global trigger or touching real audit
    // records. Parent and child predicates bind to this run's generated actor.
    sql(`BEGIN; SET LOCAL session_replication_role=replica;
      DELETE FROM private.support_case_events e USING private.support_cases c WHERE e.support_case_id=c.support_case_id AND c.created_by='${userId}' AND e.actor_id='${userId}';
      DELETE FROM private.support_cases WHERE created_by='${userId}'; COMMIT;
      UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}'`);
  }
}
