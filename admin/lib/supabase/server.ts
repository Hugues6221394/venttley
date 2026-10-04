import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";
import { createClient } from "@supabase/supabase-js";
import { activeStaffRole } from "@/lib/staff";
import { cache } from "react";
import { measuredSupabaseFetch } from "@/lib/performance";
import { fetchWithDeadline } from "@/lib/bounded";

type CookieToSet = { name: string; value: string; options?: CookieOptions };

/**
 * Cookie-bound Supabase client for Server Components. Uses the anon key,
 * so RLS still applies — appropriate for reading data scoped to the
 * authenticated admin user.
 *
 * The admin console relies on staff-bypass RLS policies (migration 0023)
 * so this client can see soft-deleted posts, private tribes, all reports,
 * etc. when the caller has user_role IN (super_admin, admin, moderator,
 * read_only_auditor).
 */
export const createSsrClient = cache(async function createSsrClient() {
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      global: { fetch: measuredSupabaseFetch },
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet: CookieToSet[]) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Server Component called from a non-Route-Handler context — the
            // cookie store is read-only there, which is fine for SELECT-only
            // requests. Middleware / Route Handlers refresh the cookies.
          }
        },
      },
    }
  );
});

/** React render-pass memoization only: no cross-request authorization cache.
 * Pages still gate their own data access; a layout is never an authorization
 * boundary for its concurrently rendered children. Mutation RPCs recheck the
 * actor in the database independently of this read optimization.
 */
export const getRenderStaff = cache(async () => {
  const ssr = await createSsrClient();
  const { data: { user }, error } = await ssr.auth.getUser();
  if (error || !user) return null;
  const [role, profile] = await Promise.all([
    activeStaffRole(ssr, user.id),
    ssr.from("users").select("anonymous_pseudonym").eq("user_id", user.id).maybeSingle(),
  ]);
  if (!role || profile.error || !profile.data) return null;
  return { userId: user.id, role, pseudonym: profile.data.anonymous_pseudonym as string };
});

/**
 * Returns true when the SUPABASE_SERVICE_ROLE_KEY env var is missing or
 * still set to the .env.local.example placeholder. We treat both as
 * "not configured" and fall back to the cookie-bound SSR client.
 */
function serviceRoleConfigured(): boolean {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return false;
  if (key.length < 40) return false; // Real Supabase keys are JWT-shaped, ~200+ chars
  if (/PASTE_YOUR|PLACEHOLDER|YOUR_KEY/i.test(key)) return false;
  return true;
}

/**
 * Throws unless the caller is staff in good standing, right now.
 *
 * This is the console's data access layer check, and it lives here rather than
 * in a layout for a reason Next is explicit about: "a layout does not control
 * whether the rest of the route renders ... a layout that hides or swaps them
 * does not stop them from running" (02-guides/authentication.md, "Layouts and
 * auth checks"). The dashboard layout returning <NotAuthorized/> therefore
 * never stopped the page beneath it from executing its own service-role reads
 * — every page under (dashboard) renders concurrently with the layout that was
 * supposed to be guarding it.
 *
 * So the guard moves to the thing being guarded. Every caller of
 * createAdminClient is a dashboard page or the audit export, all of which
 * require a staff session; there is no legitimate unauthenticated use, which
 * is what makes enforcing it here safe rather than merely convenient.
 */
async function assertActiveStaff(): Promise<void> {
  if (!(await getRenderStaff())) {
    // Deliberately terse. It surfaces through the error boundary, and the
    // person who sees it is by definition not someone to hand details to.
    throw new Error("Not authorized");
  }
}

/**
 * Admin Supabase client.
 *
 * Returns the service-role client (bypasses RLS) when a real key is in
 * env, otherwise transparently falls back to the cookie-bound SSR client.
 *
 * Gated on the caller being staff in good standing — see assertActiveStaff
 * above. Callers that need a narrower role than "staff" still check that
 * themselves; this is the floor, not the whole answer.
 *
 * Why the fallback: dev onboarding shouldn't require pasting the most
 * privileged credential in the system into .env.local. With staff RLS
 * the console works with just the anon key. The service-role key is a
 * fast-path optimisation, not a hard dependency.
 */
export async function createAdminClient() {
  await assertActiveStaff();

  if (serviceRoleConfigured()) {
    return createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
      { auth: { persistSession: false, autoRefreshToken: false }, global: { fetch: measuredSupabaseFetch } }
    );
  }
  if (process.env.NODE_ENV === "development") {
    console.warn(
      "[admin] SUPABASE_SERVICE_ROLE_KEY not configured — falling back to cookie-bound RLS client. Set it in admin/.env.local for production."
    );
  }
  return createSsrClient();
}

/**
 * Auth Admin operations must use a server-only secret and can never fall back
 * to the caller's publishable-key session. Callers must still authorize the
 * acting staff member before requesting this client.
 */
export function createRequiredAuthAdminClient(signal?: AbortSignal) {
  if (!serviceRoleConfigured()) {
    throw new Error(
      "Auth administration is unavailable: configure SUPABASE_SERVICE_ROLE_KEY."
    );
  }
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
      ...(signal ? { global: { fetch: fetchWithDeadline(signal) } } : {}),
    }
  );
}
