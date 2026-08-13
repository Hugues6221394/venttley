// account-purge
//
// Permanently erases accounts whose 30-day deletion grace period has
// elapsed. Deactivate/delete are self-serve (migration 0075):
//
//   request_account_deletion()  → sets deletion_requested_at = now()
//   reactivate_my_account()     → clears it on next successful login
//
// If the user never logs back in, this worker removes them for good.
// Because public.users.user_id is NOT a foreign key to auth.users (see
// 0001_init_schema.sql), deleting one does not cascade to the other, so
// we must delete BOTH sides per account:
//
//   1. auth.users  — via the admin API (service role). This also cascades
//                    auth.identities / sessions / refresh_tokens / mfa.
//   2. public.users — a plain delete; every child table references
//                     users(user_id) ON DELETE CASCADE, so all app data
//                     (posts, whispers, tribe memberships, chats, …) goes
//                     with it.
//
// Fail-soft per account: if the auth delete fails we skip the public-row
// delete too, leaving the account intact so it retries on the next tick.
// Idempotent: an account already gone simply isn't in the due set.
//
// Auth: JWT verification is OFF for this function (config.toml). It is
// gated instead by a shared secret — the caller must send
//   x-cron-secret: <CRON_SECRET>
// The pg_cron job (migration 0076) reads that secret from Vault. This
// keeps the endpoint un-triggerable with the public anon key.
//
// Env:
//   CRON_SECRET                                  — required; shared gate
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY     — admin client (auto-set)
//
// Schedule: once daily via pg_cron → net.http_post (see migration 0076).

import { adminClient } from "../_shared/supabase.ts";
import {
  rolloutEnabled,
  verifyInternalSecret,
} from "../_shared/internal_auth.ts";

const GRACE_DAYS = 30;
const DEFAULT_BATCH = 500;

interface DueRow {
  user_id: string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const auth = verifyInternalSecret(req, {
    envName: "CRON_SECRET",
    headerName: "x-cron-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (!rolloutEnabled("ACCOUNT_PURGE_ENABLED")) {
    return json({ ok: false, disabled: true }, 503);
  }

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const batchSize = clamp(
    typeof body?.batch === "number" ? body.batch : DEFAULT_BATCH,
    1,
    500,
  );

  const sb = adminClient();

  // Cutoff = now - 30 days. Anything requested before this is due.
  const cutoff = new Date(Date.now() - GRACE_DAYS * 86_400_000).toISOString();

  // 1) Collect the due accounts. Service role bypasses RLS + column grants.
  const { data: due, error: pickErr } = await sb
    .from("users")
    .select("user_id")
    .not("deletion_requested_at", "is", null)
    .lt("deletion_requested_at", cutoff)
    .limit(batchSize);

  if (pickErr) {
    return json({ error: "due_account_lookup_failed" }, 500);
  }

  const allDue = (due ?? []) as DueRow[];
  if (allDue.length === 0) {
    return json({ ok: true, due: 0, purged: 0, failed: 0 });
  }

  // LEGAL HOLD: never purge an account tied to an open/reported CSAM incident —
  // its content + author link must be preserved as evidence (migration 0094).
  const dueIds = allDue.map((r) => r.user_id);
  const { data: holds, error: holdError } = await sb
    .from("csam_incidents")
    .select("author_id")
    .in("author_id", dueIds)
    .in("status", ["detected", "reported"]);
  // Legal-hold lookup failure must stop deletion, never fail open.
  if (holdError) return json({ error: "legal_hold_lookup_failed" }, 500);
  const held = new Set(
    (holds ?? []).map((h) => (h as { author_id: string }).author_id),
  );
  const rows = allDue.filter((r) => !held.has(r.user_id));

  let purged = 0;
  let failed = 0;

  // 2) Delete both sides per account. Sequential on purpose — this runs
  //    once a day on a small set, and keeping it serial avoids hammering
  //    the auth admin API.
  for (const { user_id } of rows) {
    try {
      // auth.users first: if this fails we do NOT orphan the app data.
      const { error: authErr } = await sb.auth.admin.deleteUser(user_id);
      // "User not found" means auth row is already gone (a prior partial
      // run) — treat as success and continue to clean the public row.
      if (authErr && !/not.?found/i.test(authErr.message)) {
        throw new Error(`auth: ${authErr.message}`);
      }

      // public.users — cascades every child table.
      const { error: pubErr } = await sb
        .from("users")
        .delete()
        .eq("user_id", user_id);
      if (pubErr) throw new Error(`public: ${pubErr.message}`);

      purged++;
    } catch (e) {
      failed++;
      console.error(
        "account purge item failed",
        e instanceof Error ? "operation_error" : "unknown_error",
      );
    }
  }

  return json({ ok: true, due: rows.length, purged, failed });
});

// ─── Helpers ────────────────────────────────────────────────────────

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(Math.max(Math.trunc(n), lo), hi);
}
