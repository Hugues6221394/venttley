// Every dashboard route must declare who may use it.
//
// canAccess() used to return true for any path missing from SECTION_ROLES,
// so a new route was reachable by every staff role until somebody remembered
// to add it. That is how /notifications — absent from the table, and running a
// service-role fanout to every active member from an unguarded Server Action —
// stayed open to analysts and read-only auditors.
//
// canAccess() now denies unknown sections, which turns that class of mistake
// from a silent privilege escalation into a locked door. This script turns it
// into a build failure instead, so the mistake is caught before anyone ships a
// page nobody can open.
//
// Deliberately dependency-free and text-based: it runs in `npm run typecheck`
// territory without adding a test runner or a TypeScript loader to an app that
// has neither.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const dashboardDir = join(root, "app", "(dashboard)");
const rolesFile = join(root, "lib", "roles.ts");

const rolesSource = readFileSync(rolesFile, "utf8");

// The keys of SECTION_ROLES, e.g. "/users". The value may be an array literal
// or a named constant — "/overview" maps to STAFF_ROLES — so match the key and
// let the type checker worry about the value.
const sectionTable = rolesSource.slice(
  rolesSource.indexOf("const SECTION_ROLES"),
);
const declared = new Set(
  [...sectionTable.matchAll(/^\s*"(\/[a-z0-9-]+)":/gim)].map((m) => m[1]),
);

// Route groups — "(dashboard)" — are URL-invisible, so only real directories
// with a page.tsx count as sections.
const routes = readdirSync(dashboardDir)
  .filter((entry) => {
    const full = join(dashboardDir, entry);
    if (!statSync(full).isDirectory()) return false;
    if (entry.startsWith("(") || entry.startsWith("[")) return false;
    try {
      return statSync(join(full, "page.tsx")).isFile();
    } catch {
      return false;
    }
  })
  .map((entry) => `/${entry}`);

const undeclared = routes.filter((r) => !declared.has(r));
const phantom = [...declared].filter((d) => !routes.includes(d));

let failed = false;

if (undeclared.length > 0) {
  failed = true;
  console.error(
    "\nThese dashboard routes have no entry in SECTION_ROLES, so canAccess() " +
      "denies them to every role except super_admin:\n" +
      undeclared.map((r) => `  ${r}`).join("\n") +
      "\n\nAdd each one to SECTION_ROLES in lib/roles.ts with the roles that " +
      "should reach it. If a route should not exist, delete it.\n",
  );
}

if (phantom.length > 0) {
  failed = true;
  console.error(
    "\nSECTION_ROLES names routes that do not exist:\n" +
      phantom.map((r) => `  ${r}`).join("\n") +
      "\n\nA stale entry is not dangerous, but it makes the table a poor " +
      "description of the console. Remove it.\n",
  );
}

if (failed) process.exit(1);

console.log(
  `check:routes — ${routes.length} dashboard routes, all declared in SECTION_ROLES.`,
);
