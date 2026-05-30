import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";
import { createClient } from "@supabase/supabase-js";

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
export async function createSsrClient() {
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
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
}

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
 * Admin Supabase client.
 *
 * Returns the service-role client (bypasses RLS) when a real key is in
 * env, otherwise transparently falls back to the cookie-bound SSR client.
 * Either way, the admin pages only call this AFTER the layout has gated
 * the caller on user_role IN ('super_admin','admin'), and the staff-
 * bypass RLS policies (migration 0023) ensure the SSR client can read
 * the same admin views.
 *
 * Why the fallback: dev onboarding shouldn't require pasting the most
 * privileged credential in the system into .env.local. With staff RLS
 * the console works with just the anon key. The service-role key is a
 * fast-path optimisation, not a hard dependency.
 */
export async function createAdminClient() {
  if (serviceRoleConfigured()) {
    return createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
      { auth: { persistSession: false, autoRefreshToken: false } }
    );
  }
  if (process.env.NODE_ENV === "development") {
    console.warn(
      "[admin] SUPABASE_SERVICE_ROLE_KEY not configured — falling back to cookie-bound RLS client. Set it in admin/.env.local for production."
    );
  }
  return createSsrClient();
}
