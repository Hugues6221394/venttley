// Structural regression checks for the production-operations UI.
//
// These do not pretend to replace browser/RPC integration tests. They guard
// the security properties that are easy to accidentally remove while editing
// the console: one-time invite state in app_metadata, AAL2 on every staff
// mutation, invite-only callback verification, and read-only operational pages
// that must not grow direct service-role writes.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(root, path), "utf8");

let failed = false;
function expect(condition, message) {
  if (condition) return;
  failed = true;
  console.error(`check:operations — ${message}`);
}

const staffActions = read("app/(dashboard)/staff/actions.ts");
const inviteAction = read("app/invite/actions.ts");
const callback = read("app/auth/confirm/route.ts");
const loginIdentity = read("lib/supabase/client.ts");
const incidentDetail = read("app/(dashboard)/incidents/[incidentId]/page.tsx");
const emergencyAccess = read("app/(dashboard)/emergency-access/page.tsx");
const accessReviews = read("app/(dashboard)/staff/access-reviews/page.tsx");
const releaseReadiness = read("app/(dashboard)/releases/page.tsx");

expect(
  (staffActions.match(/await requireSuperAdminAal2\(\)/g) ?? []).length === 5,
  "every one of the five exported staff mutations must re-check super-admin AAL2",
);
expect(
  staffActions.includes("auth.admin.inviteUserByEmail") &&
    staffActions.includes("staff_invite_pending: true"),
  "staff invitations must use the server-only Auth Admin API and server-owned one-time state",
);
expect(
  staffActions.includes('p_role: "normal"') &&
    staffActions.includes('reqStr(formData, "confirm", 20) !== "REMOVE"'),
  "removing staff must be explicit and preserve the account by revoking its role",
);
expect(
  !staffActions.includes('.from("users").update') &&
    !staffActions.includes('.from("users").delete'),
  "staff writes must stay behind audited RPCs rather than direct service-role table mutations",
);
expect(
  inviteAction.includes("user.app_metadata.staff_invite_pending !== true") &&
    inviteAction.includes("staff_invite_pending: false"),
  "invite password setup must consume server-owned one-time state",
);
expect(
  callback.includes('type !== "invite"') &&
    callback.includes("verifyOtp") &&
    !callback.includes('searchParams.get("next")'),
  "the public callback must accept invite tokens only and must not implement an open redirect",
);
expect(
  loginIdentity.includes("return handle;") &&
    loginIdentity.includes("IDENTITY_DOMAIN"),
  "login must support real staff mailboxes without breaking member synthetic-email identities",
);
expect(
  incidentDetail.includes('key === "csam-open"') &&
    incidentDetail.includes('activeStaffRole(ssr, user.id, ["super_admin"])'),
  "CSAM incident drill-down must preserve the super-admin-only record boundary",
);
expect(
  emergencyAccess.includes('activeStaffRole(ssr, user.id, ["super_admin"])') &&
    accessReviews.includes('activeStaffRole(ssr, actor.id, ["super_admin"])'),
  "emergency access and staff access reviews must re-check active super-admin standing in their data layer",
);
expect(
  !releaseReadiness.includes('from("analytics_events")') &&
    releaseReadiness.includes("Client-version adoption is unavailable"),
  "release readiness must not globally sort the raw analytics ledger to estimate client-version adoption",
);

const readOnlyPages = [
  "app/(dashboard)/content/page.tsx",
  "app/(dashboard)/approvals/page.tsx",
  "app/(dashboard)/data-governance/page.tsx",
  "app/(dashboard)/delivery/page.tsx",
  "app/(dashboard)/evidence-access/page.tsx",
  "app/(dashboard)/emergency-access/page.tsx",
  "app/(dashboard)/feed-integrity/page.tsx",
  "app/(dashboard)/incidents/page.tsx",
  "app/(dashboard)/integrity/page.tsx",
  "app/(dashboard)/jobs/page.tsx",
  "app/(dashboard)/moderation/abuse/page.tsx",
  "app/(dashboard)/moderation/policies/page.tsx",
  "app/(dashboard)/moderation/quality/page.tsx",
  "app/(dashboard)/music/page.tsx",
  "app/(dashboard)/privacy/page.tsx",
  "app/(dashboard)/policy/versions/page.tsx",
  "app/(dashboard)/queue-control/page.tsx",
  "app/(dashboard)/releases/page.tsx",
  "app/(dashboard)/security/page.tsx",
  "app/(dashboard)/staff/invitations/page.tsx",
  "app/(dashboard)/staff/access-reviews/page.tsx",
  "app/(dashboard)/tribe-governance/page.tsx",
  "app/(dashboard)/youth-safety/page.tsx",
];

for (const page of readOnlyPages) {
  const source = read(page);
  expect(source.includes('export const dynamic = "force-dynamic"'), `${page} must never be statically cached`);
  expect(source.includes("createAdminClient"), `${page} must use the self-gating admin data client`);
  expect(!/\.insert\s*\(|\.update\s*\(|\.delete\s*\(|\.upsert\s*\(/.test(source), `${page} must remain read-only until an audited mutation contract exists`);
}

if (failed) process.exit(1);
console.log("check:operations — staff invite and read-only control contracts hold.");
