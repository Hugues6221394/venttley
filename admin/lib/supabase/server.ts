import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { createClient } from "@supabase/supabase-js";

/**
 * Cookie-bound Supabase client for Server Components. Uses the anon key,
 * so RLS still applies — appropriate for reading data scoped to the
 * authenticated admin user (e.g. their own profile row).
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
        setAll(cookiesToSet) {
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
 * Service-role Supabase client. **Bypasses RLS** — only use it inside
 * Server Components / Route Handlers we have already gated on
 * `users.user_role == 'super_admin'`.
 */
export function createAdminClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY is not set. Copy .env.local.example to .env.local and fill it in."
    );
  }
  return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
