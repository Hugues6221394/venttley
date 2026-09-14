// Nothing may read with the service-role client without checking standing.
//
// createAdminClient() bypasses RLS completely. That is the point of it — the
// console has to read across every member's rows — but it means the only thing
// deciding who sees the moderation queue, the audit log, the session list and
// every account on the platform is whatever check sits above the call.
//
// For a long time that check asked one question: "is this a staff role?".
// Which is not the same question as "may this person use the console". They
// diverged the moment 20261018090000 taught the database that a suspended or
// deactivated account is not staff whatever role is still written on its row.
// After that, a suspended moderator could not *act* — every privileged RPC
// calls is_staff and refuses — but could still *see* everything, because the
// reads never went near an RPC. Suspension is the action taken when trust is
// gone, so that was exactly the wrong half to leave standing.
//
// The first attempt at a fix put the check in the dashboard layout. That does
// not work, and Next says so directly: "a layout does not control whether the
// rest of the route renders ... a layout that hides or swaps them does not
// stop them from running" (02-guides/authentication.md). Every page under
// (dashboard) renders concurrently with the layout meant to be guarding it, so
// its service-role reads ran regardless of what the layout returned.
//
// So the guard sits inside createAdminClient itself — the thing being guarded
// — and this script checks the two properties that keeps true:
//
//   1. createAdminClient calls assertActiveStaff.
//   2. Nobody builds a service-role client any other way — the key and the
//      supabase-js constructor appear together in exactly one file. A second
//      would be a gate with a door beside it.
//
// Deliberately dependency-free and text-based, like check-routes.mjs: it runs
// in `npm run typecheck` without adding a test runner to an app that has none.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const appDir = join(root, "app");

/** Every .ts/.tsx file under app/. */
function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      out.push(...walk(full));
    } else if (/\.(ts|tsx)$/.test(entry)) {
      out.push(full);
    }
  }
  return out;
}

// The call, not the name. A first version matched "activeStaffRole" and so
// matched the import line too — remove the call, leave the import, and the
// check went on passing. A gate check that cannot fail is worse than none,
// because it is cited as evidence.
const GATE = "assertActiveStaff(";
const SERVER_FILE = join(root, "lib", "supabase", "server.ts");
const KEY = "SUPABASE_SERVICE_ROLE_KEY";

let failed = false;

// 1) The client gates itself.
const serverSource = readFileSync(SERVER_FILE, "utf8");
const adminFn = serverSource.slice(
  serverSource.indexOf("export async function createAdminClient"),
);
if (!adminFn.includes(GATE)) {
  failed = true;
  console.error(
    "\ncreateAdminClient does not call assertActiveStaff.\n\n" +
      "It returns a client that bypasses RLS entirely. Without the check, " +
      "every dashboard page reads the moderation queue, the audit log and " +
      "every session on the platform for whoever asks — and the layout cannot " +
      "prevent it, because a layout does not stop its child segments from " +
      "rendering.\n",
  );
}

// 2) Nothing constructs one behind its back.
const leaked = [];
for (const dir of [appDir, join(root, "lib"), join(root, "components")]) {
  let files;
  try {
    files = walk(dir);
  } catch {
    continue;
  }
  for (const file of files) {
    if (file === SERVER_FILE) continue;
    const src = readFileSync(file, "utf8");
    // Both, not either. Several pages read the key's *presence* to show a
    // "configured" badge and never touch its value; flagging those made the
    // check cry wolf on its first run. Constructing a client needs the
    // constructor as well as the key.
    if (src.includes(KEY) && /from ["']@supabase\/supabase-js["']/.test(src)) {
      leaked.push(relative(root, file));
    }
  }
}

if (leaked.length > 0) {
  failed = true;
  console.error(
    "\nThe service-role key is read outside lib/supabase/server.ts:\n" +
      leaked.map((f) => `  ${f}`).join("\n") +
      "\n\nThat is a second way to build an RLS-bypassing client, and it does " +
      "not pass through assertActiveStaff. Route it through createAdminClient.\n",
  );
}

if (failed) process.exit(1);

console.log(
  "check:gates — createAdminClient gates itself, and it is the only way to one.",
);
