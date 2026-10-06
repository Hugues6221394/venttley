// Local-only design screenshots of the production build with the production
// presentation flags. Uses a disposable super_admin account that is removed on
// exit. Never saves cookies, tokens or HTML; only PNGs of synthetic local data.
//   DESIGN_LABEL=before|after  DESIGN_SKIP_BUILD=1  DESIGN_ORIGIN=http://127.0.0.1:3000
import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdir, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { createServerClient } from "@supabase/ssr";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ? pathToFileURL(process.env.PLAYWRIGHT_MODULE).href : "playwright");
const config = JSON.parse(execFileSync("supabase", ["status", "-o", "json"], {
  cwd: resolve(root, ".."), encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
}));
for (const key of ["API_URL", "DB_URL"]) {
  if (!["127.0.0.1", "localhost"].includes(new URL(config[key]).hostname)) throw new Error("Refusing remote Supabase target.");
}
const port = Number(process.env.ADMIN_TEST_PORT ?? 3117);
const origin = process.env.DESIGN_ORIGIN ?? `http://127.0.0.1:${port}`;
const env = { ...process.env, NEXT_PUBLIC_SUPABASE_URL: config.API_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY: config.ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY: config.SERVICE_ROLE_KEY, NEXT_PUBLIC_ADMIN_ENV: "local", ADMIN_REQUIRE_MFA: "false",
  ADMIN_ORIGIN_SECRET: "", ADMIN_IP_ALLOWLIST: "", NEXT_TELEMETRY_DISABLED: "1",
  ADMIN_SHELL_V2: "true", ADMIN_SHELL_V2_ROLES: "super_admin", ADMIN_OVERVIEW_V2: "true", ADMIN_THEME_UI: "true", ADMIN_INBOX_UI: "true", ADMIN_ATTENTION_UI: "true" };
const label = process.env.DESIGN_LABEL ?? "after";
const outputDir = resolve(root, ".artifacts", "redesign", label);
await mkdir(outputDir, { recursive: true });
const sql = (statement, stdio = "ignore") => execFileSync("psql", [config.DB_URL, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", statement], { encoding: "utf8", stdio: ["ignore", stdio, "pipe"] });
const service = createClient(config.API_URL, config.SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
const email = `design-shot-${suffix}@example.test`, password = `Local-${randomUUID()}-Aa1!`, pseudonym = `care${suffix.slice(0, 6)}`;
const run = (args) => new Promise((ok, fail) => {
  const child = spawn(process.execPath, [require.resolve("next/dist/bin/next"), ...args], { cwd: root, env, stdio: ["ignore", "inherit", "inherit"] });
  child.on("error", fail); child.on("exit", code => code === 0 ? ok() : fail(new Error(`next ${args[0]} failed (${code})`)));
});
let server, browser, userId;
try {
  try { sql(`SELECT private.refresh_admin_overview(p) FROM unnest(array['activity','queues','reports','regions']) p`); } catch {}
  if (!process.env.DESIGN_ORIGIN) {
    if (process.env.DESIGN_SKIP_BUILD !== "1") await run(["build", "--webpack"]);
    server = spawn(process.execPath, [require.resolve("next/dist/bin/next"), "start", "-H", "127.0.0.1", "-p", String(port)], { cwd: root, env, stdio: ["ignore", "ignore", "ignore"] });
    let ready = false;
    for (let i = 0; i < 80 && !ready; i++) {
      try { ready = (await fetch(`${origin}/login`)).ok; } catch {}
      if (!ready) await new Promise(r => setTimeout(r, 500));
    }
    if (!ready) throw new Error("Local production server did not become ready");
  }
  const created = await service.auth.admin.createUser({ email, password, email_confirm: true,
    user_metadata: { pseudonym, avatar_seed: pseudonym, birth_year: "1990", birth_month: "1" } });
  if (created.error) throw new Error("Local fixture Auth creation failed");
  userId = created.data.user.id;
  sql(`INSERT INTO public.users (user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
    VALUES ('${userId}','${pseudonym}','${pseudonym}','integration-only','Care Team','care team','${pseudonym}','super_admin','active',1990)
    ON CONFLICT (user_id) DO UPDATE SET user_role='super_admin',account_status='active'`);
  // Optional local seed; ":fixture" becomes the disposable admin's id.
  if (process.env.DESIGN_SEED) sql((await readFile(process.env.DESIGN_SEED, "utf8")).replaceAll(":fixture", userId));
  const cookies = new Map();
  const auth = createServerClient(config.API_URL, config.ANON_KEY, { cookies: {
    getAll: () => [...cookies].map(([name, value]) => ({ name, value })),
    setAll: values => values.forEach(({ name, value }) => cookies.set(name, value)),
  } });
  if ((await auth.auth.signInWithPassword({ email, password })).error) throw new Error("Local fixture sign in failed");
  const detailId = process.env.DESIGN_MEMBER ?? sql(`SELECT user_id FROM public.users WHERE anonymous_pseudonym LIKE 'design%' ORDER BY anonymous_pseudonym LIMIT 1`, "pipe").trim();
  browser = await chromium.launch({ channel: process.env.ADMIN_BROWSER_CHANNEL ?? "chrome", headless: true });
  const shots = [
    ["overview", "/overview"], ["safety", "/safety"], ["moderation", "/moderation"], ["users", "/users"],
    ["inbox", "/inbox"], ["system", "/system"], ["queue", "/queue"],
    ...(process.env.DESIGN_POST ? [["post", `/content/${process.env.DESIGN_POST}`]] : []),
    ...(process.env.DESIGN_TRIBE ? [["tribe", `/tribes/${process.env.DESIGN_TRIBE}`]] : []),
    ...(detailId ? [["user-detail", `/users/${detailId}`], ["user-contact", `/users/${detailId}?tab=communications&compose=warning`], ["user-account", `/users/${detailId}?tab=account`]] : []),
  ];
  const capture = async (name, route, theme, viewport, fullPage = false) => {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 1, colorScheme: theme === "dark" ? "dark" : "light", reducedMotion: "reduce" });
    await context.addCookies([...cookies].map(([n, value]) => ({ name: n, value, url: origin, sameSite: "Lax" })));
    await context.addInitScript(value => { try { localStorage.setItem("venttly-console-appearance-v1", value); } catch {} }, theme);
    const page = await context.newPage();
    await page.goto(`${origin}${route}`, { waitUntil: "networkidle", timeout: 90000 });
    await page.waitForTimeout(600);
    const file = resolve(outputDir, `${name}.png`);
    await page.screenshot({ path: file, fullPage });
    console.log(file);
    await context.close();
  };
  const only = process.env.DESIGN_ONLY?.split(",");
  for (const [name, route] of shots) {
    if (only && !only.includes(name)) continue;
    for (const theme of ["light", "dark"]) await capture(`${name}-${theme}`, route, theme, { width: 1440, height: 900 });
  }
  // Optional journey: claim the top claimable row, then report what the
  // database recorded. Local only, like everything else here.
  if (process.env.DESIGN_QUEUE_CLAIM === "1") {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: "reduce" });
    await context.addCookies([...cookies].map(([n, value]) => ({ name: n, value, url: origin, sameSite: "Lax" })));
    const page = await context.newPage();
    await page.goto(`${origin}/queue?kind=case`, { waitUntil: "networkidle", timeout: 90000 });
    await page.getByRole("button", { name: "Claim" }).first().click();
    await page.waitForURL(/result=/, { timeout: 30000 });
    console.log("claim result:", new URL(page.url()).searchParams.get("result"));
    await page.screenshot({ path: resolve(outputDir, "queue-claimed.png") });
    console.log("claimed cases:", sql(`SELECT count(*) FROM public.moderation_cases WHERE assignee_id='${userId}'`, "pipe").trim());
    await page.goto(`${origin}/queue?kind=support`, { waitUntil: "networkidle", timeout: 90000 });
    await page.getByRole("button", { name: "Claim" }).first().click();
    await page.waitForURL(/result=/, { timeout: 30000 });
    console.log("support claim result:", new URL(page.url()).searchParams.get("result"));
    await context.close();
  }
  if (process.env.DESIGN_SUPPORT === "1") {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: "reduce" });
    await context.addCookies([...cookies].map(([n, value]) => ({ name: n, value, url: origin, sameSite: "Lax" })));
    const page = await context.newPage();
    await page.goto(`${origin}/queue?kind=support`, { waitUntil: "networkidle", timeout: 90000 });
    await page.screenshot({ path: resolve(outputDir, "support-queue.png") });
    const href = await page.locator(".queue-actions a").last().getAttribute("href");
    console.log("conversation:", href);
    const response = await page.goto(`${origin}${href}`, { waitUntil: "networkidle", timeout: 90000 });
    console.log("conversation status:", response?.status());
    await page.screenshot({ path: resolve(outputDir, "support-conversation.png"), fullPage: true });
    await page.locator("textarea[name=body]").fill("Thanks Maya. I have released the handle; try again in the app and it should go through.");
    await page.getByRole("button", { name: "Send reply" }).click();
    const status = page.locator("form.support-reply [role=status]");
    await status.waitFor({ timeout: 30000 });
    console.log("reply result:", (await status.textContent())?.trim());
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: resolve(outputDir, "support-replied.png"), fullPage: true });
    console.log("staff messages:", sql(`SELECT count(*) FROM private.support_messages WHERE author_kind='staff' AND author_id='${userId}'`, "pipe").trim());
    await context.close();
  }
  if (process.env.DESIGN_QUEUE_ASSIGN) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: "reduce" });
    await context.addCookies([...cookies].map(([n, value]) => ({ name: n, value, url: origin, sameSite: "Lax" })));
    const page = await context.newPage();
    await page.goto(`${origin}/queue?kind=case`, { waitUntil: "networkidle", timeout: 90000 });
    const assign = page.locator("details.queue-assign").first();
    await assign.locator("summary").click();
    await assign.locator("select").selectOption({ label: process.env.DESIGN_QUEUE_ASSIGN });
    await page.screenshot({ path: resolve(outputDir, "queue-assign-open.png") });
    await assign.getByRole("button", { name: "Assign" }).click();
    await page.waitForURL(/result=/, { timeout: 30000 });
    console.log("assign result:", new URL(page.url()).searchParams.get("result"));
    await page.screenshot({ path: resolve(outputDir, "queue-assigned.png") });
    console.log("cases held by teammate:", sql(`SELECT count(*) FROM public.moderation_cases c JOIN public.users u ON u.user_id=c.assignee_id WHERE u.display_name='${process.env.DESIGN_QUEUE_ASSIGN}'`, "pipe").trim());
    await context.close();
  }
  if (!only || only.includes("overview")) {
    await capture("overview-light-full", "/overview", "light", { width: 1440, height: 900 }, true);
    await capture("overview-mobile-390", "/overview", "light", { width: 390, height: 844 });
  }
} finally {
  await browser?.close().catch(() => {});
  server?.kill("SIGTERM");
  if (userId) {
    if (process.env.DESIGN_CLEANUP) try { sql((await readFile(process.env.DESIGN_CLEANUP, "utf8")).replaceAll(":fixture", userId)); } catch {}
    await service.auth.admin.deleteUser(userId);
    try { sql(`DELETE FROM public.users WHERE user_id='${userId}'`); } catch {}
  }
}
