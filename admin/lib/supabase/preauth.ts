import "server-only";

import { createRequiredAuthAdminClient } from "./server";
import { STAFF_ROLES } from "@/lib/roles";

/**
 * The two questions the console has to answer before anyone is signed in.
 *
 * Both run with the service role and without a session, which is exactly what
 * createAdminClient refuses to do, so neither hands a client back. Each asks
 * one narrow question about staff accounts only and returns a single string to
 * the route handler that called it — nothing here is ever sent to the browser
 * as-is. Ordinary member accounts are invisible to both: the console is not a
 * member sign-in or recovery surface, and must not become a way to look one up.
 *
 * Every failure, including a missing service-role key, is "no answer". The
 * callers then behave exactly as they did before these existed.
 */

const SYNTHETIC_DOMAIN = "@id.venttly.app";
const LIVE_OUTBOX = ["queued", "sending", "sent"];

function client() {
  try {
    return createRequiredAuthAdminClient();
  } catch {
    return null;
  }
}

/**
 * The address a staff handle signs in with, when it is not the synthetic one.
 *
 * Staff invited through the console authenticate with their real mailbox, so
 * their handle (`venttly_admin`) and their GoTrue email have nothing in common.
 * Building `${handle}@id.venttly.app` for them asks GoTrue about an account
 * that does not exist and comes back "Invalid login credentials" with the
 * right password. The handle is what the console shows everywhere, so it is
 * what people type.
 */
export async function staffLoginEmail(handle: string): Promise<string | null> {
  const db = client();
  const normalized = handle.trim().toLowerCase();
  if (!db || !normalized || normalized.includes("@")) return null;

  const { data: row, error } = await db
    .from("users")
    .select("user_id")
    .eq("username_normalized", normalized)
    .in("user_role", STAFF_ROLES)
    .is("deactivated_at", null)
    .maybeSingle();
  if (error || !row) return null;

  const { data, error: authError } = await db.auth.admin.getUserById(row.user_id as string);
  const email = data?.user?.email?.toLowerCase();
  if (authError || !email || email.endsWith(SYNTHETIC_DOMAIN)) return null;
  return email;
}

/**
 * Where a password-reset code for this staff identifier actually went, if one
 * is live right now.
 *
 * Matches the identifier the way begin_password_reset does — handle, or the
 * verified recovery address itself — and then requires evidence that a code
 * was issued: an unexpired password_reset code, and its email still on its way
 * or delivered. The address returned is the code's own target, not whatever
 * the profile says now, because that is the inbox the code is in.
 */
export async function staffResetDestination(identifier: string): Promise<string | null> {
  const db = client();
  const id = identifier.trim().toLowerCase();
  if (!db || !id) return null;

  const base = () =>
    db
      .from("users")
      .select("user_id")
      .eq("recovery_email_verified", true)
      .not("recovery_email", "is", null)
      .in("user_role", STAFF_ROLES);
  // Two equality lookups rather than one .or(): the identifier is untrusted,
  // and a comma or parenthesis in it would rewrite an .or() filter string.
  const { data: rows, error } = id.includes("@")
    ? await base().eq("recovery_email", id).limit(1)
    : await base().eq("username_normalized", id).limit(1);
  const userId = rows?.[0]?.user_id as string | undefined;
  if (error || !userId) return null;

  const { data: code, error: codeError } = await db
    .from("recovery_verification_codes")
    .select("target, created_at")
    .eq("user_id", userId)
    .eq("purpose", "password_reset")
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  if (codeError || !code?.target) return null;

  const { data: mail, error: mailError } = await db
    .from("email_outbox")
    .select("outbox_id")
    .eq("user_id", userId)
    .eq("template", "password_reset")
    .eq("to_address", code.target)
    .in("status", LIVE_OUTBOX)
    .gte("created_at", code.created_at)
    .limit(1);
  if (mailError || !mail?.length) return null;

  return code.target as string;
}
