// Execute the real navigation helpers, not text contracts. No browser or DB.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";
const moduleUrl = source => `data:text/javascript;base64,${Buffer.from(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
}).outputText).toString("base64")}`;
const rolesUrl = moduleUrl(await readFile(new URL("../lib/roles.ts", import.meta.url), "utf8"));
const { STAFF_ROLES, canAccess } = await import(rolesUrl);
const source = await readFile(new URL("../lib/navigation.ts", import.meta.url), "utf8");
const rolloutSource = await readFile(new URL("../lib/shell-rollout.ts", import.meta.url), "utf8");
const { hasModernShell } = await import(moduleUrl(rolloutSource.replace('"./roles"', JSON.stringify(rolesUrl))));
const { navigationGroups, visibleNavigation, activeNavigation, safeFavorites, searchNavigation } =
  await import(moduleUrl(source.replace('"./roles"', JSON.stringify(rolesUrl))));

assert.equal(navigationGroups.length, 8);
assert.equal(navigationGroups.filter(group => group.pinned).length, 1);
for (const role of STAFF_ROLES) assert(visibleNavigation(role).length === 0 || visibleNavigation(role).some(page => page.group === "Daily work"), `${role} has a daily-work entry`);
const all = navigationGroups.flatMap(group => group.pages.map(([href]) => href));
assert.equal(new Set(all).size, all.length, "one canonical entry per page");
// Preserve every existing sidebar destination while regrouping it. The number
// is explicit so a regrouping that drops a page fails here; it goes up by one
// when a page is genuinely added, which /feedback is.
assert.equal(all.length, 59);
for (const role of STAFF_ROLES) {
  assert(visibleNavigation(role).every(page => canAccess(role, page.href)));
  assert(searchNavigation(role, "staff").every(page => canAccess(role, page.href)));
  assert(safeFavorites(role, all).every(href => canAccess(role, href)));
  assert(safeFavorites(role, all).length <= 8);
}
assert.deepEqual(visibleNavigation("suspended"), []);
assert.deepEqual(safeFavorites("support", ["/staff", "/users/private-id", "/overview?q=secret", "https://evil.test", "/overview", "/overview"]), ["/overview"]);
assert.deepEqual(safeFavorites("super_admin", { href: "/staff" }), []);
assert.equal(activeNavigation("super_admin", "/staff/invitations/opaque-id")?.href, "/staff/invitations");
assert.equal(activeNavigation("moderator", "/moderation/workforce"), undefined);
assert.equal(activeNavigation("super_admin", "/users/opaque-id")?.label, "Members");
assert.equal(searchNavigation("super_admin", "  ACCESS reviews ")[0]?.href, "/staff/access-reviews");
assert.equal(searchNavigation("super_admin", "<script>" ).length, 0);
assert.equal(hasModernShell("super_admin"), false);
assert.equal(hasModernShell("super_admin", "true"), true);
assert.equal(hasModernShell("moderator", "true"), false);
assert.equal(hasModernShell("moderator", "true", "super_admin,moderator"), true);
assert.equal(hasModernShell("super_admin", "true", "super_admin,unknown"), false);
assert.equal(hasModernShell("super_admin", "false", "super_admin"), false);
assert.equal(hasModernShell(undefined, "true"), false);
console.log("check:navigation — six-role filtering, routing, safe favorites and page search passed");
