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

/** Mirrors lib/data/services/identity_service.dart#syntheticEmail. */
export function syntheticEmail(username: string) {
  return `${username.trim().toLowerCase()}@id.venttly.app`;
}
