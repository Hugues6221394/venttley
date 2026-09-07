// Role-based least-privilege for the admin console.
//
// One source of truth for "which staff role may see which section". Used by
// the sidebar (to hide what a role can't use) AND by middleware (to hard-block
// direct navigation / deep links). Hiding a nav item is UX; the middleware
// check is the actual gate.

export type StaffRole =
  | "super_admin"
  | "admin"
  | "moderator"
  | "support"
  | "analyst"
  | "read_only_auditor";

export const STAFF_ROLES: StaffRole[] = [
  "super_admin",
  "admin",
  "moderator",
  "support",
  "analyst",
  "read_only_auditor",
];

export function isStaffRole(role: string | null | undefined): role is StaffRole {
  return !!role && (STAFF_ROLES as string[]).includes(role);
}

// Section (route prefix) → roles allowed. Everyone who reaches the console can
// see the overview; everything else is least-privilege. super_admin is implicitly
// allowed everywhere.
const SECTION_ROLES: Record<string, StaffRole[]> = {
  "/overview": STAFF_ROLES,
  "/safety": ["super_admin", "admin", "moderator", "support"],
  "/csam": ["super_admin"],
  "/moderation": ["super_admin", "admin", "moderator"],
  // Matches admin_appeal_queue's own is_staff gate. support is excluded
  // deliberately: it can triage the safety queue but cannot decide an appeal,
  // and a section that loads only to refuse every action is worse than a
  // section that is not offered.
  "/appeals": ["super_admin", "admin", "moderator"],
  "/automod": ["super_admin", "admin", "moderator"],
  "/media": ["super_admin", "admin", "moderator"],
  "/users": ["super_admin", "admin", "moderator", "support"],
  "/tribes": ["super_admin", "admin", "moderator"],
  "/broadcasts": ["super_admin", "admin"],
  "/analytics": ["super_admin", "admin", "analyst", "read_only_auditor"],
  "/ops": ["super_admin", "admin", "analyst", "read_only_auditor"],
  "/audit": ["super_admin", "admin", "read_only_auditor"],
  "/system": ["super_admin", "admin"],
  "/flags": ["super_admin", "admin"],
  "/roles": ["super_admin"],
  "/sessions": ["super_admin"],
  "/verification": ["super_admin"],
  "/settings": ["super_admin", "admin"],
};

/** The section prefix a pathname belongs to (e.g. "/users/123" → "/users"). */
export function sectionOf(pathname: string): string | null {
  const match = Object.keys(SECTION_ROLES).find(
    (s) => pathname === s || pathname.startsWith(s + "/")
  );
  return match ?? null;
}

/**
 * Paths that are intentionally not sections: the console root and the login
 * screen. Everything else must declare its roles in SECTION_ROLES.
 *
 * An explicit list, because the alternative — treating "not in the table" as
 * "allowed" — is what the bug below was.
 */
const UNSECTIONED_PATHS = new Set(["/", "/login"]);

/**
 * Whether a role may access a given pathname. Unknown sections are DENIED.
 *
 * This used to say that in the comment and do the opposite:
 *
 *     if (!section) return true; // non-sectioned paths — layout still gates staff
 *
 * A route absent from SECTION_ROLES was therefore open to every staff role,
 * including analyst and read_only_auditor. That is not a hypothetical: the
 * orphaned /notifications page was missing from the table, so any staff role
 * could reach a page whose Server Action fanned a notification out to every
 * active member using the service-role client. It has been removed and its
 * capability lives at /broadcasts, behind admin_send_broadcast, which checks
 * is_staff() in the database.
 *
 * A doc comment that contradicts its own code is worse than no comment: it
 * tells a reviewer auditing this file that the case is handled.
 *
 * Deny-by-default means adding a dashboard route without a SECTION_ROLES entry
 * makes it unreachable rather than public. `npm run check:routes` turns that
 * into a build failure instead of a surprise.
 */
export function canAccess(role: string | null | undefined, pathname: string): boolean {
  if (!isStaffRole(role)) return false;
  if (UNSECTIONED_PATHS.has(pathname)) return true;
  if (role === "super_admin") return true;
  const section = sectionOf(pathname);
  if (!section) return false;
  return SECTION_ROLES[section].includes(role);
}

/** The default landing section for a role (first section it can see). */
export function landingFor(role: string | null | undefined): string {
  if (canAccess(role, "/overview")) return "/overview";
  const first = Object.keys(SECTION_ROLES).find((s) => canAccess(role, s));
  return first ?? "/overview";
}
