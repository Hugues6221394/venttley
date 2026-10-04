// Real HTTP/SSR/RPC browser exercise; local database only. Fixtures and temporary
// delivery switch are restored in finally. No real member data is captured.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";

export async function checkInboxBrowser({ browser, cookies, origin, userId, dbUrl, outputDir }) {
  assert.equal(new URL(dbUrl).hostname, "127.0.0.1");
  const sql = statement => { try { return execFileSync("psql", [dbUrl,"-X","-At","-v","ON_ERROR_STOP=1","-c",statement], {encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim(); }
    catch (error) { throw new Error(`Local inbox fixture SQL failed: ${String(error.stderr).split("\n").filter(line=>line.startsWith("ERROR:")).join(" ")}`); } };
  const control = JSON.parse(sql("SELECT row_to_json(c) FROM private.staff_inbox_control c"));
  assert.equal(control.enabled, false, "Refuse to interfere with an enabled local pilot");
  const cron = sql("SELECT active FROM cron.job WHERE jobname='staff-inbox-dispatch'");
  const support = randomUUID(), legal = randomUUID(), author = randomUUID();
  let context;
  try {
    sql("SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname='staff-inbox-dispatch'");
    sql(`UPDATE public.users SET user_role='super_admin',account_status='active' WHERE user_id='${userId}';
      INSERT INTO private.support_cases(support_case_id,source_kind,category,assigned_to,status,sla_due_at,created_by) VALUES('${support}','other','technical','${userId}','assigned',now()-interval '1 hour','${userId}');
      INSERT INTO private.legal_requests(legal_request_id,request_type,jurisdiction,external_reference_hash,scope_code,due_at,created_by,status) VALUES('${legal}','court_order','RW',md5('${legal}')||md5('${support}'),'account_metadata',now()+interval '1 day','${author}','awaiting_approval');
      UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor'],worker_at=now();
      INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity,status) SELECT 'browser-${support}-'||i,'support_assigned','${support}','${userId}','info','delivered' FROM generate_series(1,33) i;
      INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity,status) VALUES('browser-${support}-sla','support_sla_breached','${support}','${userId}','critical','delivered'),('browser-${legal}','legal_review_requested','${legal}','${userId}','warning','delivered');
      INSERT INTO private.staff_inbox_deliveries(event_id,recipient_id) SELECT event_id,'${userId}' FROM private.staff_event_outbox WHERE source_id IN ('${support}','${legal}');`);
    context = await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:"reduce"});
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:"Lax"})));
    const page = await context.newPage();
    if (process.env.ADMIN_ATTENTION_UI === 'false') {
      for (const route of ['/overview', '/moderation', '/appeals', '/support/cases', '/legal-requests']) {
        await page.goto(`${origin}${route}`, {waitUntil:'networkidle'});
        assert.equal(await page.locator('[data-attention-panel]').count(), 0, `attention UI rollback: ${route}`);
      }
    }
    const refresh = () => page.getByRole("button",{name:"Refresh",exact:true}).first().click();
    const list = page.locator("main .inbox-list");
    for (const role of ["super_admin","admin","support","moderator","analyst","read_only_auditor"]) {
      sql(`UPDATE public.users SET user_role='${role}' WHERE user_id='${userId}'`);
      await page.goto(`${origin}/inbox`,{waitUntil:"networkidle"});
      const permitted = ["super_admin","admin","support"].includes(role);
      await page.waitForFunction(()=>!document.querySelector("main")?.textContent.includes("Loading notifications…"));
      assert.equal(await list.locator(".inbox-row").count(), permitted ? 30 : 0, `${role} recipient/source isolation`);
      assert.equal(await page.locator("main .inbox-metric strong").first().textContent(), role === "super_admin" ? "35" : permitted ? "34" : "0");
      const result = await context.request.get(`${origin}/inbox/data?mode=items&category=legal`);
      assert.equal(result.status(),200); assert.equal((await result.json()).items.length, role === "super_admin" ? 1 : 0);
      console.log(`PASS inbox real JWT / source permissions: ${role}`);
    }
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'`);
    await page.goto(`${origin}/inbox?category=legal`,{waitUntil:"networkidle"});
    assert.equal(await list.locator(".inbox-row").count(),1,"category before pagination");
    assert.equal(await list.getByRole("link",{name:/Open source/}).getAttribute("href"),`/legal-requests?source=${legal}`);
    await list.getByRole("button",{name:"Mark read",exact:true}).click();
    await page.getByText("No notifications in this view",{exact:true}).waitFor();
    assert.equal(sql(`SELECT status FROM private.legal_requests WHERE legal_request_id='${legal}'`),"awaiting_approval","reading never resolves source");
    await page.goto(`${origin}/inbox?filter=all&category=legal`,{waitUntil:"networkidle"});
    await list.getByRole("button",{name:"Mark unread",exact:true}).click();
    await list.getByRole("button",{name:"Mark read",exact:true}).waitFor();
    await page.goto(`${origin}/inbox?filter=urgent`,{waitUntil:"networkidle"});
    assert.equal(await list.locator(".inbox-row").count(),1,"urgent filter");
    await page.goto(`${origin}/inbox`,{waitUntil:"networkidle"});
    await list.getByRole("button",{name:/Older notices/}).click();
    await page.waitForFunction(()=>document.querySelectorAll("main .inbox-row").length===5);
    await list.getByRole("button",{name:"Latest notices"}).click();
    await page.waitForFunction(()=>document.querySelectorAll("main .inbox-row").length===30);
    await page.getByRole("button",{name:"Preferences",exact:true}).click();
    const preference = page.getByRole("checkbox",{name:"Receive optional assignment notifications"});
    await page.waitForFunction(()=>document.querySelector('.inbox-preferences input')?.disabled===false);
    // The controlled checkbox changes only after server confirmation, not
    // optimistically at click time. Assert the saved result after the receipt.
    await preference.click(); await page.getByText("Preference saved.",{exact:true}).waitFor(); assert.equal(await preference.isChecked(),false);
    await preference.click(); await page.getByText("Preference saved.",{exact:true}).waitFor(); assert.equal(await preference.isChecked(),true);
    await page.getByRole("button",{name:"Preferences",exact:true}).click();
    assert.equal((await context.request.get(`${origin}/inbox/data?mode=items&category=invalid`)).status(),400);
    assert.equal((await context.request.post(`${origin}/inbox/data`,{headers:{origin:"https://foreign.test"},data:{action:"read",eventId:randomUUID(),read:true}})).status(),403,"cross-origin mutation denied");
    // Capture a synthetic fixture only: all notices belong to the disposable
    // generated records; remove account name, queue aggregates and identifiers.
    async function capture(name) {
      await page.locator("header p").evaluateAll(nodes=>nodes.forEach(p=>{if(p.textContent.startsWith("@"))p.textContent="@operator"}));
      const html = await page.evaluate(()=>{
        const shell=document.querySelector(".operator-shell-v2").cloneNode(true);
        shell.querySelectorAll("script").forEach(n=>n.remove());
        shell.querySelectorAll("a").forEach(n=>n.setAttribute("href","#"));
        shell.querySelectorAll(".inbox-queue-links,.inbox-queue-badge,aside .pill").forEach(n=>n.remove());
        const css=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules].map(r=>r.cssText)}catch{return []}}).join("\n");
        return `<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style></head><body><p>SYNTHETIC LOCAL TEST DATA · not a live production inbox</p>${shell.outerHTML}</body></html>`;
      });
      await writeFile(resolve(outputDir,`${name}.html`),html);
      await page.screenshot({path:resolve(outputDir,`${name}.png`)});
    }
    await capture("synthetic-inbox");
    const bell = page.getByRole("button",{name:/Open staff inbox/});
    await bell.click(); const drawer = page.getByRole("dialog",{name:"Unread notifications"}); await drawer.waitFor();
    await drawer.locator(".inbox-row").first().waitFor();
    await capture("synthetic-inbox-drawer");
    await page.keyboard.press("Shift+Tab"); assert(await drawer.evaluate(d=>d.contains(document.activeElement)));
    await page.keyboard.press("Escape"); assert(await bell.evaluate(b=>b===document.activeElement));
    await page.setViewportSize({width:390,height:844}); await bell.click(); await drawer.waitFor();
    await drawer.locator(".inbox-row").first().waitFor();
    assert(await drawer.evaluate(d=>d.getBoundingClientRect().width<=innerWidth));
    await capture("synthetic-inbox-mobile"); await page.keyboard.press("Escape");
    await page.setViewportSize({width:1440,height:1000});
    // Failed refresh must clear prior privileged data and show unknown, not 0.
    await page.route("**/inbox/data*",route=>route.fulfill({status:503,contentType:"application/json",body:'{"error":"Unavailable"}'}));
    await refresh(); await page.getByText("Notifications unavailable",{exact:true}).waitFor();
    assert.equal(await list.locator(".inbox-row").count(),0);
    assert.equal(await page.locator("main .inbox-metric strong").first().textContent(),"—");
    await page.unroute("**/inbox/data*"); await refresh(); await list.locator(".inbox-row").first().waitFor();
    // Slow read retains the filter and shows loading feedback without inventing
    // an empty success. This delays only this local test browser's response.
    await page.route("**/inbox/data?mode=items*",async route=>{ await new Promise(resolve=>setTimeout(resolve,800)); await route.continue(); });
    await page.getByRole("link",{name:"Urgent",exact:true}).click();
    await page.waitForURL(/filter=urgent/);
    await page.waitForFunction(()=>document.querySelectorAll("main .inbox-row").length===1);
    assert.equal(await list.locator(".inbox-row").count(),1);
    await page.unroute("**/inbox/data?mode=items*");
    let attentionReads=0;
    const countRead = request=>{ if(request.url().includes("/inbox/data?mode=attention"))attentionReads++; };
    page.on("request",countRead);
    await page.waitForTimeout(31_500); assert(attentionReads>=1,"visible page polls after 30 seconds");
    await page.evaluate(()=>{Object.defineProperty(document,"hidden",{configurable:true,get:()=>true});document.dispatchEvent(new Event("visibilitychange"));});
    const readsWhileHidden=attentionReads; await page.waitForTimeout(31_500);
    assert.equal(attentionReads,readsWhileHidden,"hidden page pauses polling");
    await page.evaluate(()=>{delete document.hidden;document.dispatchEvent(new Event("visibilitychange"));window.dispatchEvent(new Event("focus"));});
    await page.waitForTimeout(1200); assert(attentionReads>readsWhileHidden,"focus resumes refresh");
    page.off("request",countRead);
    // Runtime role revocation, no new login or navigation required.
    sql(`UPDATE public.users SET user_role='analyst' WHERE user_id='${userId}'`);
    await refresh(); await page.getByText("No notifications in this view",{exact:true}).waitFor();
    assert.equal(await list.locator(".inbox-row").count(),0);
    sql(`UPDATE public.users SET user_role='super_admin' WHERE user_id='${userId}'; UPDATE private.staff_inbox_control SET enabled=false;`);
    await refresh(); await page.getByText("Inbox pilot is not enabled",{exact:true}).waitFor();
    console.log("PASS inbox filters, read/unread, preferences, pagination, CSRF, keyboard/mobile, slow/failed refresh, visible polling, hidden pause, focus, permission change and rollback");
  } finally {
    await context?.close();
    sql(`UPDATE private.staff_inbox_control SET enabled=false;
      DELETE FROM private.staff_inbox_deliveries WHERE event_id IN (SELECT event_id FROM private.staff_event_outbox WHERE source_id IN ('${support}','${legal}'));
      DELETE FROM private.staff_event_outbox WHERE source_id IN ('${support}','${legal}');
      DELETE FROM private.support_cases WHERE support_case_id='${support}'; DELETE FROM private.legal_requests WHERE legal_request_id='${legal}';
      UPDATE private.staff_inbox_control SET audience_roles=ARRAY[${control.audience_roles.map(r=>`'${r}'`).join(",")}],worker_at=${control.worker_at ? `'${control.worker_at}'::timestamptz` : "NULL"};
      SELECT cron.alter_job(jobid,active:=${cron === "t"}) FROM cron.job WHERE jobname='staff-inbox-dispatch';`);
  }
}
