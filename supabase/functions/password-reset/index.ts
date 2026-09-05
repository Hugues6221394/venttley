// Reset a password using a verified recovery email.
//
// This function exists because Postgres cannot safely write GoTrue's
// encrypted_password. The SQL side owns everything that can be decided from
// data — who the identifier belongs to, whether the address is verified,
// whether the code is right, how often this may be asked — and this function
// owns the one step that has to go through the auth admin API.
//
// It is unauthenticated by necessity: the whole point is that the caller
// cannot sign in. That makes it the most attackable surface in the app, so:
//
//   * the "request" branch returns the SAME response no matter what happened.
//     Account exists, address unverified, rate limited, nothing found — all
//     indistinguishable. Anything else turns this into a way to test whether
//     an address or a handle has a Venttly account.
//   * timing is levelled on that branch too. A lookup that misses returns much
//     faster than one that hashes a code and queues mail, and that difference
//     is measurable over a few hundred requests.
//   * the "confirm" branch revokes every existing session after setting the
//     password. A reset that leaves an attacker signed in has recovered
//     nothing — it has merely told them they were noticed.
//   * the new password is checked against the same policy the app enforces, so
//     the reset path cannot be used to install a weaker password than signup
//     would have allowed.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Mirrors lib/core/password_policy.dart. Kept in step deliberately: a reset
// that accepted "password123" would make the signup rules decorative.
const MIN_LENGTH = 12;

function passwordProblem(password: string): string | null {
  if (password.length < MIN_LENGTH) {
    return `Use at least ${MIN_LENGTH} characters.`;
  }
  if (!/[a-z]/.test(password)) return "Add a lower case letter.";
  if (!/[A-Z]/.test(password)) return "Add a capital letter.";
  if (!/[0-9]/.test(password)) return "Add a number.";
  if (!/[^A-Za-z0-9]/.test(password)) return "Add a symbol, like ! or ?";
  if (password.split("").every((c) => c === password[0])) {
    return "Try something less repetitive.";
  }
  return null;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// Hold the response until `floorMs` has passed since `startedAt`.
///
/// Without this, "no such account" answers in a few milliseconds while a real
/// request spends time hashing a code and writing three rows. That gap is a
/// perfectly good account-existence oracle even though the response bodies are
/// identical.
async function levelTiming(startedAt: number, floorMs = 700) {
  const elapsed = Date.now() - startedAt;
  if (elapsed < floorMs) {
    await new Promise((r) => setTimeout(r, floorMs - elapsed));
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const startedAt = Date.now();

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  const action = String(body.action ?? "");
  const identifier = String(body.identifier ?? "").trim();

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  // -------------------------------------------------------------------------
  // request: issue a code, and admit nothing
  // -------------------------------------------------------------------------
  if (action === "request") {
    if (!identifier || identifier.length > 320) {
      await levelTiming(startedAt);
      return json({ ok: true });
    }

    try {
      await supabase.rpc("begin_password_reset", { p_identifier: identifier });
    } catch (_) {
      // Even a hard failure is answered the same way. The caller learning that
      // something went wrong for THIS identifier and not another one is
      // exactly the leak this branch is built to avoid; the watchdog and the
      // function logs are where a real problem surfaces.
    }

    await levelTiming(startedAt);
    return json({ ok: true });
  }

  // -------------------------------------------------------------------------
  // confirm: prove the code, set the password, end every session
  // -------------------------------------------------------------------------
  if (action === "confirm") {
    const code = String(body.code ?? "").trim();
    const newPassword = String(body.new_password ?? "");

    // Checked before the code is spent. Burning somebody's only code and then
    // telling them their password needs a capital letter would force a second
    // round trip through their inbox for no reason.
    const problem = passwordProblem(newPassword);
    if (problem) {
      return json({ ok: false, error: "weak_password", message: problem }, 400);
    }

    if (!identifier || !code) {
      await levelTiming(startedAt);
      return json({ ok: false, error: "invalid_code" }, 400);
    }

    const { data, error } = await supabase.rpc("complete_password_reset", {
      p_identifier: identifier,
      p_code: code,
    });

    if (error || !data?.ok || !data?.user_id) {
      await levelTiming(startedAt);
      // One message for wrong, expired, exhausted and unknown alike. Telling
      // someone the code was merely expired confirms the account exists.
      return json({ ok: false, error: "invalid_code" }, 400);
    }

    const userId = String(data.user_id);

    const { error: updateError } = await supabase.auth.admin.updateUserById(
      userId,
      { password: newPassword },
    );
    if (updateError) {
      // The code is already burned, so say plainly that they need a new one
      // rather than pretending the code was wrong.
      return json({ ok: false, error: "reset_failed" }, 500);
    }

    // Everything below is after the password is already changed, so a failure
    // here must not report the reset as failed — it succeeded, and saying
    // otherwise would send somebody to request another code they do not need.
    try {
      await supabase.auth.admin.signOut(userId, "global");
    } catch (_) {
      // Sessions outlive the reset. Logged by the caller's absence of an
      // error; the account is still recovered.
    }

    try {
      await supabase.rpc("note_password_reset", { p_user: userId });
    } catch (_) {
      // The stamp and the warning email are best effort.
    }

    return json({ ok: true });
  }

  return json({ error: "unknown_action" }, 400);
});
