import type { SupabaseClient } from "@supabase/supabase-js";
import { STAFF_ROLES, isStaffRole, type StaffRole } from "./roles";

/**
 * The role a caller may act with right now, or null.
 *
 * Both console gates — the proxy's front door and the dashboard layout — used
 * to ask only "is this a staff role?". That is not the same question as "may
 * this person use the console", and the two answers diverged the moment
 * 20261018090000 taught the database that a suspended or deactivated account is
 * not staff regardless of the role still written on it.
 *
 * After that migration a suspended moderator could not *do* anything: every
 * privileged RPC calls is_staff and refuses. But they could still *see*
 * everything. The layout gated on role, then built a service-role client and
 * read with RLS bypassed — eighteen pages do — so suspending someone removed
 * their ability to act and left the reports queue, the audit log, sessions and
 * roles fully readable. Suspension is precisely the action taken when trust is
 * gone, which makes that the wrong half to leave standing.
 *
 * So this asks the database rather than restating its rule in TypeScript. A
 * second copy of "what counts as staff" is what produced the gap, and a second
 * copy would drift again the next time the rule gains a condition — a
 * suspension end date, say, or a required MFA factor. is_staff is granted to
 * `authenticated` and evaluated under the caller's own RLS, so it is safe to
 * ask with the user-scoped client and answers about the caller alone.
 *
 * The role is still read separately because section authorization
 * (lib/roles.ts) needs to know *which* role, which is a question is_staff does
 * not answer.
 *
 * `roles` narrows the question for callers that need more than staffhood —
 * the audit export, for instance, is limited to super_admin, admin and
 * read_only_auditor. Passing the narrow list here rather than checking the
 * role afterwards means those endpoints get the standing check too, which is
 * the whole point: every gate should be asking the same function.
 */
export async function activeStaffRole(
  supabase: SupabaseClient,
  userId: string,
  roles: readonly string[] = STAFF_ROLES
): Promise<StaffRole | null> {
  const [roleResult, staffResult] = await Promise.all([
    supabase
      .from("users")
      .select("user_role")
      .eq("user_id", userId)
      .maybeSingle(),
    supabase.rpc("is_staff", { p_user: userId, p_roles: roles }),
  ]);

  // Fail closed. A network blip, an RLS change, a renamed function — none of
  // those are evidence that this person may read the moderation queue, and
  // treating an error as a pass is how a gate becomes decorative.
  if (roleResult.error || staffResult.error) return null;
  if (staffResult.data !== true) return null;

  const role = roleResult.data?.user_role as string | undefined;
  return isStaffRole(role) ? role : null;
}
