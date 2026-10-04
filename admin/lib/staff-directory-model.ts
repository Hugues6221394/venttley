import type { SupabaseClient } from "@supabase/supabase-js";

export const directoryRoles = ["super_admin", "admin", "moderator", "support", "analyst", "read_only_auditor"] as const;
export const directoryStatuses = ["all", "active", "inactive"] as const;
export const STAFF_PAGE_SIZE = 25;
export type DirectoryPath = "/staff" | "/staff/invitations" | "/staff/access-reviews";
export type DirectoryFilters = {
  role: "all" | typeof directoryRoles[number];
  status: typeof directoryStatuses[number];
  after: string | null;
};

// These URLs contain queue metadata only: never mailbox, name or reason text.
export function directoryFilters(params: Record<string, string | string[] | undefined>): DirectoryFilters | null {
  const { role = "all", status = "all", after } = params;
  if (typeof role !== "string" || !["all", ...directoryRoles].includes(role) ||
      typeof status !== "string" || !(directoryStatuses as readonly string[]).includes(status) ||
      (after !== undefined && (typeof after !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(after)))) return null;
  return { role: role as DirectoryFilters["role"], status: status as DirectoryFilters["status"], after: after?.toLowerCase() ?? null };
}

export function directoryHref(filters: DirectoryFilters, after?: string, path: DirectoryPath = "/staff") {
  const params = new URLSearchParams({ role: filters.role, status: filters.status });
  if (after) params.set("after", after);
  return `${path}?${params}`;
}

/** Caller MUST independently verify active super-admin standing first.
 * Immutable-ID keysets avoid offset drift when roles/status change. Membership
 * is live, not a snapshot: restarting is required after a concurrent change.
 */
export function staffDirectoryQuery(db: SupabaseClient, filters: DirectoryFilters, signal = AbortSignal.timeout(6_000)) {
  let query = db.from("users").select(
    "user_id, display_name, anonymous_pseudonym, user_role, account_status, deactivated_at, created_at, last_seen_at",
  ).in("user_role", directoryRoles).order("user_id").limit(STAFF_PAGE_SIZE + 1);
  if (filters.role !== "all") query = query.eq("user_role", filters.role);
  if (filters.status === "active") query = query.eq("account_status", "active").is("deactivated_at", null);
  if (filters.status === "inactive") query = query.or("account_status.neq.active,deactivated_at.not.is.null");
  if (filters.after) query = query.gt("user_id", filters.after);
  return query.abortSignal(signal);
}

/** Separate from filters and pagination. Two rows suffice to protect the last
 * super admin in the UI; the audited mutation RPC remains authoritative.
 */
export function activeSuperAdminQuery(db: SupabaseClient, signal = AbortSignal.timeout(6_000)) {
  return db.from("users").select("user_id").eq("user_role", "super_admin")
    .eq("account_status", "active").is("deactivated_at", null).limit(2).abortSignal(signal);
}
