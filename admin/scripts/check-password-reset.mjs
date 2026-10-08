// Console sign-in and recovery: the masked inbox, and the limits around it.
//
// The masking rules are executed; the rest is text-level, like
// check-service-role-gates.mjs, because the properties that matter are about
// what the route handlers are allowed to send back to an anonymous caller.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";

const read = (p) => readFile(new URL(`../${p}`, import.meta.url), "utf8");

const source = await read("lib/mask-email.ts");
const js = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
}).outputText;
const { maskEmail } = await import(`data:text/javascript;base64,${Buffer.from(js).toString("base64")}`);

assert.equal(maskEmail("hugues@gmail.com"), "hu•••••es@gmail.com");
assert.equal(maskEmail("alexandria.smith@example.org"), "al•••••th@example.org");
assert.equal(maskEmail("abcde@x.io"), "a•••••e@x.io");
assert.equal(maskEmail("abcd@x.io"), "a•••••d@x.io");
assert.equal(maskEmail("abc@x.io"), "a•••••@x.io");
assert.equal(maskEmail("ab@x.io"), "•••••@x.io");
assert.equal(maskEmail("a@x.io"), "•••••@x.io");
assert.equal(maskEmail("  hugues@gmail.com "), "hu•••••es@gmail.com");
for (const bad of [null, undefined, "", "nobody", "@x.io", "abc@"]) {
  assert.equal(maskEmail(bad), null, `maskEmail(${JSON.stringify(bad)})`);
}
// Never the whole local part, for any length.
for (let n = 1; n <= 12; n++) {
  const local = "abcdefghijkl".slice(0, n);
  const masked = maskEmail(`${local}@x.io`);
  assert.ok(!masked.startsWith(`${local}@`), `length ${n} revealed whole local part`);
  const visible = masked.split("@")[0].replaceAll("•", "").length;
  assert.ok(visible <= Math.max(0, n - 2) && visible <= 4, `length ${n} shows ${visible}`);
}

const preauth = await read("lib/supabase/preauth.ts");
const reset = await read("app/api/auth/password-reset/route.ts");
const login = await read("app/api/auth/login/route.ts");

// Staff only, in both lookups: the console must not become a member oracle.
assert.equal(
  (preauth.match(/\.in\("user_role", STAFF_ROLES\)/g) ?? []).length,
  2,
  "both pre-auth lookups must be restricted to staff roles",
);
assert.ok(preauth.startsWith('import "server-only";'), "preauth.ts must be server-only");
assert.ok(!/export\s+(async\s+)?function\s+client/.test(preauth), "preauth must not export a client");
assert.ok(!/^\s*\.or\(/m.test(preauth), "untrusted identifiers must not be spliced into .or() filters");
// A code was really issued: live code, and its mail not skipped or failed.
assert.match(preauth, /\.gt\("expires_at"/);
assert.match(preauth, /LIVE_OUTBOX = \["queued", "sending", "sent"\]/);

// The reset route returns only the masked form, and only after the upstream
// call succeeded; every other path is the bare generic answer.
assert.match(reset, /maskEmail\(await staffResetDestination\(identifier\)\)/);
assert.ok(!/sentTo:\s*await/.test(reset), "raw destination must never be returned");
assert.match(reset, /if \(!upstream\.ok\) return NextResponse\.json\(\{ ok: true \}\);/);
assert.ok(
  reset.indexOf("limiter.limit(") < reset.indexOf("staffResetDestination("),
  "the rate limit must run before any lookup",
);

// Sign-in resolves staff handles server-side, after the rate limit, and falls
// back to the synthetic address.
assert.match(login, /\(await staffLoginEmail\(username\)\) \?\? syntheticEmail\(username\)/);
assert.ok(
  login.indexOf("loginLimiter.limit(") < login.indexOf("staffLoginEmail(username)"),
  "the rate limit must run before the handle lookup",
);

console.log(
  "check:password-reset — masking never reveals a whole local part; staff-only lookups run after the rate limit and return only a masked inbox.",
);
