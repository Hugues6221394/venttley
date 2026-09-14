import { createBrowserClient } from "@supabase/ssr";

/**
 * Browser-side Supabase client. Used by the login form and any future
 * client-component mutations. Backed by the anon key — RLS applies.
 */
export function createBrowserSupabase() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}

const IDENTITY_DOMAIN = "@id.venttly.app";

/**
 * Mirrors lib/data/services/identity_service.dart#syntheticEmail.
 *
 * Tolerates the domain already being present. The field is labelled Username,
 * but the address it builds is what everything else in the project displays —
 * seeds, docs, the auth table — so typing the whole thing is the natural
 * mistake, and appending blindly produced
 * `tester_admin@id.venttly.app@id.venttly.app` and an "Invalid login
 * credentials" that says nothing about why. It cost a debugging cycle on the
 * first staging sign-in; the credentials were correct the whole time.
 */
export function syntheticEmail(username: string) {
  const handle = username.trim().toLowerCase();
  return handle.endsWith(IDENTITY_DOMAIN) ? handle : `${handle}${IDENTITY_DOMAIN}`;
}
