// Requires a disposable, real local session created by profile-console.
// Real role/standing checks first; synthetic read fixtures then cover UI states.
// No production targets, real staff mutations, screenshots or raw data logging.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {STAFF_ROLES,landingFor} from '../lib/roles.ts';
import {staffFixtureId} from './staff-fault-proxy.mjs';

export async function checkStaffBrowser({browser,cookies,origin,userId,dbUrl,proxy}) {
  for(const url of [dbUrl,origin])assert(['127.0.0.1','localhost'].includes(new URL(url).hostname),'Local target required');
  assert(/^[0-9a-f-]{36}$/.test(userId));
  const sql=statement=>{
    try{return execFileSync('psql',[dbUrl,'-X','-At','-v','ON_ERROR_STOP=1','-c',statement],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();}
    catch{throw Error('Local staff fixture query failed');}
  };
  const paths=['/staff','/staff/invitations','/staff/access-reviews'];
  let context;
  try {
    context=await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'});
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    const page=await context.newPage();let pageErrors=0;
    page.on('pageerror',()=>pageErrors++);
    const visit=path=>page.goto(`${origin}${path}`,{waitUntil:'networkidle',timeout:60000});
    for(const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}',account_status='active' WHERE user_id='${userId}'`);
      for(const path of paths) {
        const before=proxy.control.calls.directory;
        await visit(path);
        assert.equal(new URL(page.url()).pathname,role==='super_admin'?path:landingFor(role),'staff direct URL gate');
        if(role!=='super_admin')assert.equal(proxy.control.calls.directory,before,'denied role issues no privileged directory read');
        else assert.equal(await page.getByRole('form',{name:'Filter staff directory'}).count(),1);
      }
    }
    sql(`UPDATE public.users SET user_role='super_admin',account_status='suspended' WHERE user_id='${userId}'`);
    for(const path of paths) {
      const before=proxy.control.calls.directory;
      await visit(path);
      assert.equal(await page.getByRole('form',{name:'Filter staff directory'}).count(),0,'suspended staff sees no directory controls');
      assert.equal(proxy.control.calls.directory,before,'suspended staff issues no directory read');
    }
    sql(`UPDATE public.users SET account_status='active' WHERE user_id='${userId}'`);
    console.log('PASS staff real-session direct URLs for six roles and suspended standing');

    // Fresh disposable session is AAL1. Exercise a real rejected server action
    // without inviting anyone or changing a target's access. Inputs and URL stay.
    await visit('/staff?role=moderator&status=active');
    const grant=page.getByRole('form',{name:'Grant access',exact:true});
    await grant.getByRole('textbox',{name:'Immutable user ID'}).fill(userId);
    await grant.getByRole('textbox',{name:'Business reason'}).fill('Synthetic retained input');
    await grant.getByRole('combobox',{name:'Role',exact:true}).selectOption('support');
    let actionRequests=0;
    const countAction=request=>{if(request.method()==='POST'&&request.headers()['next-action'])actionRequests++;};
    page.on('request',countAction);
    await grant.getByRole('button',{name:'Grant access',exact:true}).click();
    await grant.getByRole('button',{name:'Confirm grant access',exact:true}).evaluate(button=>{button.click();button.click();});
    await grant.getByRole('alert').filter({hasText:'Complete MFA'}).waitFor();
    page.off('request',countAction);
    assert.equal(actionRequests,1,'double confirmation sends one pending mutation');
    assert.equal(await grant.getByRole('textbox',{name:'Business reason'}).inputValue(),'Synthetic retained input');
    assert.equal(await grant.getByRole('combobox',{name:'Role',exact:true}).inputValue(),'support');
    assert.equal(new URL(page.url()).searchParams.get('role'),'moderator');
    assert.equal(sql(`SELECT user_role FROM public.users WHERE user_id='${userId}'`),'super_admin','MFA refusal has no mutation');
    console.log('PASS staff real AAL1 refusal, retained inputs/filter URL and duplicate-click protection');

    // UI data only is fictional; the authenticated actor's gates remain live.
    proxy.control.synthetic=true;
    for(const path of paths) {
      await visit(`${path}?role=moderator&status=active`);
      const filters=page.getByRole('form',{name:'Filter staff directory'});
      assert.equal(await filters.getByRole('combobox',{name:'Staff role'}).inputValue(),'moderator');
      await page.getByRole('link',{name:'Next page',exact:true}).click();
      await page.waitForURL(url=>url.pathname===path&&url.searchParams.get('after')===staffFixtureId(25));
      assert.equal(new URL(page.url()).searchParams.get('status'),'active');
      assert.equal(await page.getByRole('link',{name:'Next page',exact:true}).count(),0);
      await page.getByRole('link',{name:'First page',exact:true}).click();
      await page.waitForURL(url=>url.pathname===path&&!url.searchParams.has('after'));
      assert.equal(new URL(page.url()).searchParams.get('role'),'moderator');
      // Keyboard submission and field labels work without pointer-only controls.
      await filters.getByRole('combobox',{name:'Staff role'}).selectOption('analyst');
      await filters.getByRole('button',{name:'Apply filters'}).focus();await page.keyboard.press('Enter');
      await page.waitForURL(url=>url.searchParams.get('role')==='analyst');
      assert.equal(await page.getByRole('link',{name:'Next page',exact:true}).count(),0);
      await visit(`${path}?role=moderator&role=admin`);
      await page.getByText('Invalid staff filters',{exact:true}).waitFor();
      const authBefore=proxy.control.calls.auth;
      proxy.control.mode='auth-failed';await visit(path);
      assert(proxy.control.calls.auth>authBefore,`${path}: Auth fault must actually be exercised`);
      const incompleteTitle=path==='/staff'?'Some staff mailbox status is unavailable':path==='/staff/invitations'?'Invitation picture is incomplete':'Access-review evidence is incomplete';
      await page.getByText(incompleteTitle,{exact:true}).waitFor();
      const unknownAuth=(await page.locator('main').innerText()).toLowerCase().includes('unknown');
      if(!unknownAuth)console.log(JSON.stringify({stage:'staff-auth-failure',route:path,authRequests:proxy.control.calls.auth-authBefore,sourceWarnings:await page.locator('[data-console-state="unavailable"],[data-console-state="warning"]').count(),sampleRows:await page.getByText(/^Sample Operator \d+$/).count()}));
      assert(unknownAuth,`${path}: failed Auth is unknown`);
      assert.equal(await page.getByText('none on this page',{exact:true}).count(),path==='/staff/access-reviews'?1:0,'Auth-dependent metrics never imply healthy');
      proxy.control.mode='directory-failed';await visit(path);
      assert((await page.locator('main').innerText()).includes(path==='/staff'?'Staff directory could not be loaded':'Staff records could not be loaded'),'query failure stays explicit');
      proxy.control.mode='normal';
      await page.setViewportSize({width:390,height:844});await visit(path);
      assert(await filters.getByRole('button',{name:'Apply filters'}).isVisible());
      assert(await page.locator('main').evaluate(main=>main.getBoundingClientRect().right<=innerWidth+1),'staff workspace fits narrow viewport');
      await page.setViewportSize({width:1440,height:1000});
    }
    proxy.control.mode='protection-failed';await visit('/staff');
    await page.getByText('Super-admin safety count is unavailable',{exact:true}).waitFor();
    proxy.control.mode='slow';await visit('/staff?role=moderator');
    assert.equal(await page.getByRole('link',{name:'Next page',exact:true}).count(),1,'delayed read still yields a usable queue');
    proxy.control.mode='normal';
    // Same cookies after role change: no re-login can mask stale permissions.
    sql(`UPDATE public.users SET user_role='analyst' WHERE user_id='${userId}'`);
    const before=proxy.control.calls.directory;await visit('/staff');
    assert.equal(new URL(page.url()).pathname,landingFor('analyst'));
    assert.equal(proxy.control.calls.directory,before);
    assert.equal(await page.getByRole('form',{name:'Filter staff directory'}).count(),0);
    assert.equal(pageErrors,0,'staff pages have no uncaught browser exceptions');
    console.log('PASS staff synthetic read states: cursor/filter navigation, empty pages, failures, keyboard/mobile, delayed read and live role loss');
  } finally {
    proxy.control.mode='normal';proxy.control.synthetic=false;
    try {await context?.close();} finally {
      sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}'`);
    }
  }
}
