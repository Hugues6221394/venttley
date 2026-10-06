// Local-only production-build browser baseline. Never saves cookies, tokens,
// HTML, console messages, or member content. Uses a disposable local account.
import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { createServerClient } from "@supabase/ssr";
import assert from "node:assert/strict";
import { canAccess, STAFF_ROLES } from "../lib/roles.ts";
import { checkInboxBrowser } from "./test-inbox-browser.mjs";
import { checkOverviewBrowser } from "./test-overview-browser.mjs";
import { overviewFaultProxy } from "./overview-fault-proxy.mjs";
import { checkAttentionBrowser } from "./test-attention-browser.mjs";
import { checkWorkflowBrowser } from './test-workflow-browser.mjs';
import { workflowFaultProxy } from './workflow-fault-proxy.mjs';
import { checkRecoveryBrowser } from './test-recovery-browser.mjs';
import { checkModerationNotices } from './test-moderation-notices.mjs';
import { checkJobReportNotices } from './test-job-report-notices.mjs';
import { checkIncidentBrowser } from './test-incident-browser.mjs';
import { checkStaffBrowser } from './test-staff-browser.mjs';
import { staffFaultProxy } from './staff-fault-proxy.mjs';
import { checkAllRoutesBrowser } from './test-all-routes-browser.mjs';
import { checkThemeBrowser } from './test-theme-browser.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE
  ? pathToFileURL(process.env.PLAYWRIGHT_MODULE).href : "playwright");
const config = JSON.parse(execFileSync("supabase", ["status", "-o", "json"], {
  cwd: resolve(root, ".."), encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
}));
for (const key of ["API_URL", "DB_URL"]) {
  if (!["127.0.0.1", "localhost"].includes(new URL(config[key]).hostname)) {
    throw new Error("Browser fixtures require local Supabase. Refusing remote target.");
  }
}
const port = Number(process.env.ADMIN_TEST_PORT ?? 3107);
const origin = `http://127.0.0.1:${port}`;
const env = { ...process.env, NEXT_PUBLIC_SUPABASE_URL: config.API_URL,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: config.ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY: config.SERVICE_ROLE_KEY,
  NEXT_PUBLIC_ADMIN_ENV: "local", ADMIN_REQUIRE_MFA: "false",
  ADMIN_ORIGIN_SECRET: "", ADMIN_IP_ALLOWLIST: "", NEXT_TELEMETRY_DISABLED: "1",
  ADMIN_PROFILE_METRICS: "1" };
if (process.env.ADMIN_INBOX_ASSERT === "1") env.ADMIN_INBOX_UI = "true";
if(process.env.ADMIN_THEME_ASSERT) {
  assert(['1','rollback'].includes(process.env.ADMIN_THEME_ASSERT),'invalid theme gate');
  env.ADMIN_THEME_UI=process.env.ADMIN_THEME_ASSERT==='1'?'true':'false';
  env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
  env.ADMIN_INBOX_UI='false';env.ADMIN_ATTENTION_UI='false';
}
if(process.env.ADMIN_INCIDENT_ASSERT==='1') {
  env.ADMIN_ATTENTION_UI='true';
  env.ADMIN_INCIDENTS_UI='true';env.ADMIN_INBOX_UI='true';env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
}
if (process.env.ADMIN_MODERATION_NOTICES_ASSERT === '1') {
  env.ADMIN_INBOX_UI='true';env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
}
if(process.env.ADMIN_JOB_REPORT_ASSERT==='1') {
  env.ADMIN_INBOX_UI='true';env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
  env.ADMIN_ATTENTION_UI='true';env.ADMIN_INBOX_RECOVERY_UI='true';
}
if(process.env.ADMIN_RECOVERY_ASSERT==='1') {
  env.ADMIN_INBOX_RECOVERY_UI='true';env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
  env.ADMIN_INBOX_UI='false';env.ADMIN_ATTENTION_UI='false';
}
if (process.env.ADMIN_ATTENTION_ASSERT === "1") {
  env.ADMIN_ATTENTION_UI = "true";
  env.ADMIN_OVERVIEW_V2 = "true";
  env.ADMIN_SHELL_V2 = "true";
  env.ADMIN_SHELL_V2_ROLES = STAFF_ROLES.join(',');
  env.ADMIN_INBOX_UI = "false"; // Independent UI rollback must not stop queue refresh.
}
if (process.env.ADMIN_MODERN_SHELL_ASSERT === "1") {
  env.ADMIN_SHELL_V2 = "true";
  env.ADMIN_SHELL_V2_ROLES = STAFF_ROLES.join(",");
}
const service = createClient(config.API_URL, config.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
const email = `console-${suffix}@example.test`;
const password = `Local-${randomUUID()}-Aa1!`;
const pseudonym = `console${suffix}`;
const outputDir = resolve(root, ".artifacts", process.env.ADMIN_PROFILE_LABEL ?? "baseline");
await mkdir(outputDir, { recursive: true });
let userId, server, browser, overviewProxy;
const timings = [];
const run = (args) => new Promise((res, rej) => {
  const child = spawn(process.execPath, [require.resolve("next/dist/bin/next"), ...args], {
    cwd: root, env, stdio: ["ignore", "pipe", "pipe"],
  });
  // Avoid dumping environment/configuration or request content on failure.
  child.stdout.resume(); child.stderr.resume();
  child.on("error", rej);
  child.on("exit", code => code === 0 ? res() : rej(new Error(`Next ${args[0]} failed (${code})`)));
});
try {
  if(process.env.ADMIN_STAFF_ASSERT==='1') {
    overviewProxy=await staffFaultProxy(config.API_URL);
    env.NEXT_PUBLIC_SUPABASE_URL=overviewProxy.url;
    env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
    env.ADMIN_INBOX_UI='false';env.ADMIN_ATTENTION_UI='false';
  }
  if(process.env.ADMIN_WORKFLOW_ASSERT==='1') {
    overviewProxy=await workflowFaultProxy(config.API_URL);
    env.NEXT_PUBLIC_SUPABASE_URL=overviewProxy.url;
    env.ADMIN_WORKFLOWS_UI='true';env.ADMIN_SHELL_V2='true';env.ADMIN_SHELL_V2_ROLES=STAFF_ROLES.join(',');
    env.ADMIN_ATTENTION_UI='false';env.ADMIN_INBOX_UI='false';env.ADMIN_OVERVIEW_V2='false';
  }
  if (process.env.ADMIN_OVERVIEW_ASSERT === "1") {
    overviewProxy = await overviewFaultProxy(config.API_URL);
    env.NEXT_PUBLIC_SUPABASE_URL = overviewProxy.url;
    env.ADMIN_OVERVIEW_V2 = "true";
    env.ADMIN_SHELL_V2 = "true";
    env.ADMIN_SHELL_V2_ROLES = STAFF_ROLES.join(",");
  }
  console.log("Building admin against local Supabase (production mode)…");
  if (process.env.ADMIN_PROFILE_SKIP_BUILD !== "1") await run(["build", "--webpack"]);
  server = spawn(process.execPath, [require.resolve("next/dist/bin/next"), "start", "-H", "127.0.0.1", "-p", String(port)], {
    cwd: root, env, stdio: ["ignore", "pipe", "pipe"],
  });
  let partialLine = "";
  server.stdout.on("data", chunk => {
    partialLine += chunk.toString();
    const lines = partialLine.split("\n"); partialLine = lines.pop();
    for (const line of lines) if (line.startsWith("ADMIN_TIMING ")) {
      try { timings.push(JSON.parse(line.slice(13))); } catch {}
    }
  });
  server.stderr.resume();
  let ready = false;
  for (let attempt = 0; attempt < 60; attempt++) {
    if (server.exitCode !== null) throw new Error("Production server exited before ready");
    try { if ((await fetch(`${origin}/login`)).ok) { ready = true; break; } } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  if (!ready) throw new Error("Local production server did not become ready");
  const created = await service.auth.admin.createUser({ email, password, email_confirm: true,
    user_metadata: { pseudonym, avatar_seed: pseudonym, birth_year: "1990", birth_month: "1" } });
  if (created.error) throw new Error("Local fixture Auth creation failed");
  userId = created.data.user.id;
  // Fixed SQL with validated generated UUID/ASCII values, local target only.
  execFileSync("psql", [config.DB_URL, "-X", "-v", "ON_ERROR_STOP=1", "-c",
    `INSERT INTO public.users (user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
     VALUES ('${userId}','${pseudonym}','${pseudonym}','integration-only','Console Test','console test','${pseudonym}','super_admin','active',1990)
     ON CONFLICT (user_id) DO UPDATE SET user_role='super_admin',account_status='active'`], { stdio: "ignore" });
  const cookies = new Map();
  const auth = createServerClient(config.API_URL, config.ANON_KEY, { cookies: {
    getAll: () => [...cookies].map(([name, value]) => ({ name, value })),
    setAll: values => values.forEach(({ name, value }) => cookies.set(name, value)),
  }});
  const login = await auth.auth.signInWithPassword({ email, password });
  if (login.error) throw new Error("Local fixture sign in failed");
  browser = await chromium.launch({ channel: process.env.ADMIN_BROWSER_CHANNEL ?? "chrome", headless: true });
  const rows = [];
  for (const route of ["/login", "/overview", "/moderation", "/support/cases", "/incidents", "/impact"]) {
    for (let sample = 0; sample < Number(process.env.ADMIN_PROFILE_SAMPLES ?? 3); sample++) {
      const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
      if (route !== "/login") await context.addCookies([...cookies].map(([name, value]) => ({ name, value, url: origin, sameSite: "Lax" })));
      const page = await context.newPage();
      const timingStart = timings.length;
      await page.addInitScript(() => {
        window.__consoleMetrics = { lcp: null, cls: 0 };
        new PerformanceObserver(list => {
          for (const entry of list.getEntries()) window.__consoleMetrics.lcp = entry.startTime;
        }).observe({ type: "largest-contentful-paint", buffered: true });
        new PerformanceObserver(list => {
          for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.__consoleMetrics.cls += entry.value;
        }).observe({ type: "layout-shift", buffered: true });
      });
      const response = await page.goto(`${origin}${route}`, { waitUntil: "networkidle", timeout: 60000 });
      await page.waitForTimeout(250);
      const actual = new URL(page.url()).pathname;
      const metrics = await page.evaluate(() => {
        const nav = performance.getEntriesByType("navigation")[0];
        return { ttfbMs: nav.responseStart, documentMs: nav.responseEnd,
          domContentLoadedMs: nav.domContentLoadedEventEnd,
          scriptTransferBytes: performance.getEntriesByType("resource").filter(r => r.initiatorType === "script").reduce((sum,r) => sum+r.transferSize,0),
          ...window.__consoleMetrics };
      });
      const roundTrips = timings.slice(timingStart);
      const result = { route, sample, status: response.status(), reachedRequestedRoute: actual === route, ...metrics,
        serverRoundTrips: roundTrips.length || null,
        serverRoundTripMs: roundTrips.length ? roundTrips.reduce((sum,t) => sum+t.durationMs,0) : null,
        serverRoundTripsByCategory: Object.fromEntries(["auth","rpc","query"].map(c => [c, roundTrips.filter(t => t.category===c).length])),
      };
      rows.push(result); console.log(JSON.stringify(result));
      if (route === "/overview" && sample === 0 && process.env.ADMIN_SYNTHETIC_REFERENCE === "1") {
        // Explicit synthetic reconstruction: no source metrics/content is sent
        // to design services. Capture keeps only the existing shared chrome.
        await page.locator("main").evaluate(main => {
          main.innerHTML = '<div style="max-width:1100px"><p class="h-eyebrow">COMMAND CENTER · SYNTHETIC DESIGN FIXTURE</p><h1 class="h-display" style="margin:16px 0">Your team’s next best action</h1><p class="text-ink-muted">A calm workspace for a safer community. All data below is fictional.</p><div style="display:grid;grid-template-columns:repeat(3,1fr);gap:20px;margin:32px 0"><div class="stat"><p>Needs review</p><strong style="font-size:30px">24</strong></div><div class="stat"><p>Assigned to you</p><strong style="font-size:30px">8</strong></div><div class="stat"><p>Response deadlines</p><strong style="font-size:30px">3</strong></div></div><section class="surface" style="padding:28px"><h2 class="h-section">Priority work</h2><p style="padding:24px 0;border-bottom:1px solid #ddd">Safety case · Assigned · Due in 12 minutes</p><p style="padding:24px 0;border-bottom:1px solid #ddd">Moderation review · Unassigned · Due in 45 minutes</p><p style="padding:24px 0">Support case · In progress · Due in 2 hours</p></section></div>';
        });
        await page.locator("header").evaluate(header => {
          header.querySelectorAll("p").forEach(p => { if (p.textContent?.startsWith("@")) p.textContent = "@operator"; });
          header.querySelectorAll("button > span").forEach(span => span.remove());
        });
        await page.locator("main h1").evaluate(heading => { heading.className = "h-page"; });
        await page.locator("aside .pill").evaluateAll(elements => elements.forEach(el => el.remove()));
        await page.screenshot({ path: resolve(outputDir, "synthetic-shell.png") });
        if (process.env.ADMIN_MODERN_SHELL_ASSERT === "1") {
          // Save only the reconstructed fixture and CSS, never the actual
          // document/RSC scripts (which may include real database responses).
          const captureFixture = async name => {
            const html = await page.evaluate(() => {
              const shell = document.querySelector(".operator-shell-v2").cloneNode(true);
              shell.querySelectorAll("script").forEach(element => element.remove());
              shell.querySelectorAll("a").forEach(element => element.setAttribute("href", "#"));
              shell.querySelectorAll("input").forEach(element => { element.value = ""; element.removeAttribute("value"); });
              const css = [...document.styleSheets].flatMap(sheet => { try { return [...sheet.cssRules].map(rule=>rule.cssText); } catch { return []; } }).join("\n");
              return `<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style></head><body>${shell.outerHTML}</body></html>`;
            });
            await writeFile(resolve(outputDir, `${name}.html`), html);
            await page.screenshot({ path: resolve(outputDir, `${name}.png`) });
          };
          await captureFixture("synthetic-shell");
          await page.getByRole("button",{name:"Find a page",exact:true}).click();
          await page.getByRole("dialog",{name:"Page navigation search"}).waitFor();
          await captureFixture("synthetic-page-search");
          await page.keyboard.press("Escape");
          await page.setViewportSize({width:390,height:844});
          await page.getByRole("button",{name:"Open navigation",exact:true}).click();
          await page.getByRole("dialog",{name:"Workspace navigation"}).waitFor();
          await captureFixture("synthetic-mobile-navigation");
        }
      }
      await context.close();
    }
  }
  if (process.env.ADMIN_SHELL_ASSERT === "1") {
    assert(process.env.ADMIN_INBOX_ASSERT === "1" || rows.filter(row=>row.route!=="/login").every(row=>row.serverRoundTripsByCategory.auth===1),
      "shared data-access auth check should run once per measured render (proxy excluded)");
    const sql = statement => execFileSync("psql", [config.DB_URL,"-X","-v","ON_ERROR_STOP=1","-c",statement], { stdio: "ignore" });
    for (const role of STAFF_ROLES) {
      sql(`UPDATE public.users SET user_role='${role}',account_status='active' WHERE user_id='${userId}'`);
      const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
      await context.addCookies([...cookies].map(([name,value]) => ({name,value,url:origin,sameSite:"Lax"})));
      const page = await context.newPage();
      await page.goto(`${origin}/overview`, {waitUntil:"networkidle"});
      assert.equal(new URL(page.url()).pathname,"/overview", `${role} has overview access`);
      const links = await page.locator("aside nav a").evaluateAll(links => links.map(a=>a.getAttribute("href")));
      assert(links.every(href => canAccess(role,new URL(href,origin).pathname)),`${role} navigation must be permission scoped`);
      assert.equal(await page.getByRole("textbox",{name:"Search members and content (audited)"}).count(),canAccess(role,"/search")?1:0);
      await page.getByRole("button",{name:"Account menu"}).click();
      assert.equal(await page.locator("#staff-account-menu a[href='/settings']").count(),canAccess(role,"/settings")?1:0);
      assert.equal(await page.locator("#staff-account-menu a[href='/audit']").count(),canAccess(role,"/audit")?1:0);
      await page.keyboard.press("Escape");
      assert.equal(await page.getByRole("button",{name:"Account menu"}).getAttribute("aria-expanded"),"false");
      if (process.env.ADMIN_MODERN_SHELL_ASSERT === "1") {
        assert.equal(await page.locator(".operator-shell-v2").count(),1);
        await page.getByRole("button",{name:"Favorite",exact:true}).click();
        assert.equal(await page.getByRole("button",{name:"Saved",exact:true}).getAttribute("aria-pressed"),"true");
        assert.equal(await page.locator(".operator-favorites a[href='/overview']").count(),1);
        await page.getByRole("button",{name:"Compact view",exact:true}).click();
        assert.equal(await page.locator(".operator-shell-v2").getAttribute("data-density"),"compact");
        await page.getByRole("button",{name:"Find a page",exact:true}).click();
        const search = page.getByRole("dialog",{name:"Page navigation search"});
        await search.waitFor();
        await page.getByRole("textbox",{name:"Find an admin page"}).fill("Staff accounts");
        assert.equal(await search.locator(".operator-search-results button").count(),canAccess(role,"/staff")?1:0);
        await page.getByRole("textbox",{name:"Find an admin page"}).fill("Home");
        await page.keyboard.press("ArrowDown");
        assert(await search.locator(".operator-search-results button").first().evaluate(button=>button===document.activeElement),"arrow keys focus actual page result");
        await page.keyboard.press("Escape");
        assert(await page.getByRole("button",{name:"Find a page",exact:true}).evaluate(button=>button===document.activeElement),"search returns focus to trigger");
        await page.emulateMedia({reducedMotion:"reduce"});
        for (const width of [768,390]) {
          await page.setViewportSize({width,height:844});
          await page.getByRole("button",{name:"Open navigation",exact:true}).click();
          const drawer = page.getByRole("dialog",{name:"Workspace navigation"});
          await drawer.waitFor();
          assert(await drawer.evaluate(element=>element.matches(":modal")),"navigation is a modal, background inert");
          await page.keyboard.press("Shift+Tab");
          assert(await drawer.evaluate(element=>element.contains(document.activeElement)),"drawer traps keyboard focus");
          await page.keyboard.press("Escape");
          assert(await page.getByRole("button",{name:"Open navigation",exact:true}).evaluate(button=>button===document.activeElement),"drawer restores trigger focus");
          assert(await page.locator("header").first().evaluate(element=>element.getBoundingClientRect().right<=innerWidth+1),"topbar fits narrow viewport");
        }
        console.log(`PASS modern shell search, favorites, density, mobile and keyboard: ${role}`);
      }
      await page.goto(`${origin}/staff`, {waitUntil:"networkidle"});
      assert.equal(new URL(page.url()).pathname,role==="super_admin"?"/staff":"/overview",`${role} direct URL authorization`);
      const attention = await auth.rpc("admin_staff_attention");
      assert.equal(attention.error,null,`${role} can call actor-bound attention RPC`);
      assert.equal(attention.data.enabled,false,"inbox rollout stays disabled by default");
      console.log(`PASS role navigation, direct URL and attention: ${role}`);
      await context.close();
    }
    sql(`UPDATE public.users SET user_role='super_admin',account_status='suspended' WHERE user_id='${userId}'`);
    const denied = await auth.rpc("admin_staff_attention");
    assert(denied.error,"real JWT from suspended staff cannot read inbox");
    const context = await browser.newContext();
    await context.addCookies([...cookies].map(([name,value])=>({name,value,url:origin,sameSite:"Lax"})));
    const page=await context.newPage();
    await page.goto(`${origin}/overview`,{waitUntil:"networkidle"});
    assert.equal(await page.locator("aside nav").count(),0,"suspended account has no staff shell");
    await context.close();
    console.log("PASS suspended account rejected with existing JWT");
  }
  if (process.env.ADMIN_INBOX_ASSERT === "1") await checkInboxBrowser({ browser, cookies, origin, userId, dbUrl: config.DB_URL, outputDir });
  if(process.env.ADMIN_THEME_ASSERT)await checkThemeBrowser({browser,cookies,origin,enabled:process.env.ADMIN_THEME_ASSERT==='1'});
  if (process.env.ADMIN_OVERVIEW_ASSERT === "1") await checkOverviewBrowser({ browser, cookies, origin, userId, dbUrl: config.DB_URL, outputDir, proxy: overviewProxy });
  if (process.env.ADMIN_ATTENTION_ASSERT === "1") await checkAttentionBrowser({ browser, cookies, origin, userId, dbUrl: config.DB_URL, outputDir });
  if(process.env.ADMIN_WORKFLOW_ASSERT==='1')await checkWorkflowBrowser({browser,cookies,origin,userId,dbUrl:config.DB_URL,outputDir,auth,proxy:overviewProxy});
  if(process.env.ADMIN_RECOVERY_ASSERT==='1')await checkRecoveryBrowser({browser,cookies,origin,userId,dbUrl:config.DB_URL,outputDir,auth});
  if(process.env.ADMIN_MODERATION_NOTICES_ASSERT==='1')await checkModerationNotices({browser,cookies,origin,userId,dbUrl:config.DB_URL,auth});
  if(process.env.ADMIN_JOB_REPORT_ASSERT==='1')await checkJobReportNotices({browser,cookies,origin,userId,dbUrl:config.DB_URL,auth});
  if(process.env.ADMIN_INCIDENT_ASSERT==='1')await checkIncidentBrowser({browser,cookies,origin,userId,dbUrl:config.DB_URL,auth,outputDir,monitorEnv:{NOTIFICATION_MONITOR_URL:config.API_URL,NOTIFICATION_MONITOR_SERVICE_KEY:config.SERVICE_ROLE_KEY}});
  if(process.env.ADMIN_STAFF_ASSERT==='1')await checkStaffBrowser({browser,cookies,origin,userId,dbUrl:config.DB_URL,proxy:overviewProxy});
  if(process.env.ADMIN_ALL_ROUTES_ASSERT==='1')await checkAllRoutesBrowser({browser,cookies,origin,userId,dbUrl:config.DB_URL,outputDir,root,fixtures:JSON.parse(process.env.ADMIN_ROUTE_FIXTURES??'{}')});
  await writeFile(resolve(outputDir, "browser-baseline.json"), JSON.stringify({
    measuredAt: new Date().toISOString(), browser: await browser.version(), viewport: "1440x1000",
    network: "local loopback, unthrottled", data: "existing local fixture database; not production scale",
    mode: "production build; fresh browser context per sample; server warmed by readiness check",
    limitations: ["No field INP measurement", "Not a concurrency/capacity test", "No claim of production SLO compliance", "Round-trip instrumentation covers shared data-access clients, not proxy or Postgres CPU time", "Local AAL1 read-only fixture; MFA mutation tests are separate"], rows,
  }, null, 2));
  if (rows.some(row => !row.reachedRequestedRoute || row.status !== 200)) throw new Error("At least one requested route failed or redirected; baseline is incomplete");
  console.log(`Saved redacted baseline to ${outputDir}`);
} finally {
  try {
    await browser?.close();
  } finally {
    server?.kill("SIGTERM");
    await overviewProxy?.close();
    if (userId) {
      const removed = await service.auth.admin.deleteUser(userId);
      execFileSync("psql", [config.DB_URL, "-X", "-v", "ON_ERROR_STOP=1", "-c", `DELETE FROM public.users WHERE user_id='${userId}'`], { stdio: "ignore" });
      if (removed.error) throw new Error("Local Auth fixture cleanup failed; inspect local test accounts before rerunning.");
    }
  }
}
