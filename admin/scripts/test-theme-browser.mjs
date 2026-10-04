// Real production-build DOM with the harness's local disposable account.
// No source writes, content captures, screenshots, cookies or storage dumps.
import assert from 'node:assert/strict';

export async function checkThemeBrowser({browser,cookies,origin,enabled}) {
  assert(['127.0.0.1','localhost'].includes(new URL(origin).hostname),'local target only');
  const contexts=[];
  const create=async(options={})=>{
    const context=await browser.newContext({viewport:{width:1280,height:900},colorScheme:'dark',reducedMotion:'reduce',...options});
    contexts.push(context);
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:'Lax'})));
    return context;
  };
  const scheme=page=>page.evaluate(()=>getComputedStyle(document.documentElement).colorScheme);
  const go=async(page,path='/overview')=>{
    const response=await page.goto(`${origin}${path}`,{waitUntil:'networkidle'});
    assert.equal(response.status(),200);assert.equal(new URL(page.url()).pathname,path,'authorized route must render');
  };
  const choose=async(page,value)=>{
    const menu=page.getByRole('button',{name:'Account menu',exact:true});
    if(await menu.getAttribute('aria-expanded')!=='true')await menu.click();
    const select=page.getByLabel('Appearance',{exact:true});
    await select.selectOption(value);
    assert.equal(await select.inputValue(),value);
  };
  try {
    const context=await create();const page=await context.newPage();
    await go(page);
    if(!enabled) {
      await page.getByRole('button',{name:'Account menu',exact:true}).click();
      assert.equal(await page.getByLabel('Appearance',{exact:true}).count(),0);
      assert.equal(await scheme(page),'light','rollout off ignores dark device');
      await page.evaluate(()=>localStorage.setItem('venttly-console-appearance-v1','dark'));
      await page.reload({waitUntil:'networkidle'});
      assert.equal(await scheme(page),'light','rollout off ignores saved preference');
      console.log('PASS theme UI rollback (real browser)');return;
    }
    assert.equal(await scheme(page),'dark','system follows device before selection');
    await choose(page,'light');assert.equal(await scheme(page),'light');
    await choose(page,'dark');assert.equal(await scheme(page),'dark');
    await page.reload({waitUntil:'networkidle'});assert.equal(await scheme(page),'dark','saved choice survives reload');
    await go(page,'/analytics');
    await page.getByRole('heading',{name:'Analytics',exact:true}).waitFor();
    assert.equal(await scheme(page),'dark','analytics uses the shared appearance');
    await page.getByRole('navigation',{name:'Analytics chart window'}).getByRole('link',{name:'7d',exact:true}).click();
    await page.waitForURL(url=>url.pathname==='/analytics'&&url.searchParams.get('range')==='7d');
    await page.getByRole('heading',{name:'Daily activity and signups',exact:true}).waitFor();
    assert.equal(await scheme(page),'dark','chart filter navigation preserves theme');
    await go(page,'/inbox');assert.equal(await scheme(page),'dark','shared navigation preserves choice');
    await choose(page,'system');await page.emulateMedia({colorScheme:'light'});assert.equal(await scheme(page),'light');
    await page.emulateMedia({colorScheme:'dark'});assert.equal(await scheme(page),'dark','system follows live OS changes');
    const other=await context.newPage();await go(other);
    await choose(page,'light');
    await other.waitForFunction(()=>document.documentElement.dataset.theme==='light');
    await page.setViewportSize({width:320,height:740});
    await choose(page,'dark');
    assert(await page.locator('#staff-account-menu').evaluate(el=>{const r=el.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth+1;}),'appearance control fits narrow screen');
    const select=page.getByLabel('Appearance',{exact:true});await select.focus();
    assert(await select.evaluate(el=>el===document.activeElement),'native selector keyboard focus');
    assert(await select.evaluate(el=>getComputedStyle(el).outlineStyle!=='none'),'visible focus indicator');
    await page.keyboard.press('Escape');
    assert(await page.getByRole('button',{name:'Account menu',exact:true}).evaluate(el=>el===document.activeElement),'menu restores focus');
    // Storage failure must leave a usable control and truthful feedback.
    const blocked=await create();await blocked.addInitScript(()=>Object.defineProperty(window,'localStorage',{get(){throw new DOMException('Blocked','SecurityError');}}));
    const blockedPage=await blocked.newPage();await go(blockedPage);await choose(blockedPage,'light');
    assert.equal(await scheme(blockedPage),'light');await blockedPage.getByText('Applied in this tab. Your browser could not save the preference.',{exact:true}).waitFor();
    const noJs=await create({javaScriptEnabled:false});const plain=await noJs.newPage();await go(plain);
    assert.equal(await scheme(plain),'dark','CSS system fallback without hydration');
    console.log('PASS theme browser: preferences, reload/navigation, OS/cross-tab changes, narrow/keyboard use, blocked storage and no-JS fallback');
  } finally {for(const context of contexts)await context.close();}
}
