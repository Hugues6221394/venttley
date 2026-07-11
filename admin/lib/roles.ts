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

/** Whether a role may access a given pathname. Unknown sections default deny. */
export function canAccess(role: string | null | undefined, pathname: string): boolean {
  if (role === "super_admin") return true;
  if (!isStaffRole(role)) return false;
  const section = sectionOf(pathname);
  if (!section) return true; // non-sectioned paths (e.g. "/") — layout still gates staff
  return SECTION_ROLES[section].includes(role);
}

/** The default landing section for a role (first section it can see). */
export function landingFor(role: string | null | undefined): string {
  if (canAccess(role, "/overview")) return "/overview";
  const first = Object.keys(SECTION_ROLES).find((s) => canAccess(role, s));
  return first ?? "/overview";
}
