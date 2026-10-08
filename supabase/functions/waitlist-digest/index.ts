// waitlist-digest
//
// Mails the addresses collected by venttly.com/waitlist to the team, once a
// day, and marks them reported so nobody is sent twice and nobody is skipped.
//
// Why this is not a template in email-dispatcher: that function exists to send
// mail *to members*, keyed on a user row, with unsubscribe wording and brand
// shell. This is an internal operations report with no user on either end. It
// is also the only path by which the waitlist leaves the database, which is
// easier to assert about when it is one short file rather than one branch
// inside a larger dispatcher.
//
// The claim is transactional: public.claim_waitlist_digest() stamps
// notified_at and returns the rows it stamped, with FOR UPDATE SKIP LOCKED, so
// an overlapping run gets the rest rather than the same list again. The cost
// of that choice is that a send failure loses a day's addresses from the
// digest -- they stay in the table, they are simply not re-reported -- so the
// failure is logged loudly and the total is always included, which is what
// makes a gap noticeable.
//
// Auth: JWT verification is OFF (config.toml). The caller must present
//   x-cron-secret: <CRON_SECRET>
// which the pg_cron job reads from Vault (migration 20261082090000).
//
// Env:
//   CRON_SECRET                                — required; shared gate
//   RESEND_API_KEY                             — required to send
//   RESEND_FROM_ADDRESS                        — verified sender
//   WAITLIST_DIGEST_TO                         — recipient; defaults below
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY   — admin client (auto-set)
//
// Schedule: daily 06:30 UTC via pg_cron → net.http_post.

import { adminClient } from "../_shared/supabase.ts";
import { verifyInternalSecret } from "../_shared/internal_auth.ts";

const DEFAULT_TO = "info@codafriqa.rw";

interface Signup {
  email: string;
  created_at: string;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Escape anything bound for the HTML part. Addresses are attacker-supplied. */
function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso: string): string {
  // Fixed, unambiguous, and in the timezone the cron is described in, so a
  // row's time in the mail matches the time in the database.
  return new Date(iso).toISOString().replace("T", " ").slice(0, 16) + " UTC";
}

function textBody(signups: Signup[], total: number): string {
  const lines = signups.map((s) => `  ${s.email}  ${formatWhen(s.created_at)}`);
  return [
    `${signups.length} new signup${signups.length === 1 ? "" : "s"} ` +
    `on the Venttly waitlist.`,
    "",
    ...lines,
    "",
    `Total on the waitlist: ${total}`,
    "",
    "These people asked to be told when Venttly launches. They have not",
    "agreed to anything else.",
  ].join("\n");
}

function htmlBody(signups: Signup[], total: number): string {
  const rows = signups
    .map(
      (s) =>
        `<tr><td style="padding:4px 12px 4px 0;font-family:monospace">` +
        `${escapeHtml(s.email)}</td>` +
        `<td style="padding:4px 0;color:#6b5560">` +
        `${escapeHtml(formatWhen(s.created_at))}</td></tr>`,
    )
    .join("");
  return `<div style="font-family:system-ui,sans-serif;color:#2b1620">
  <p><strong>${signups.length} new signup${
    signups.length === 1 ? "" : "s"
  }</strong> on the Venttly waitlist.</p>
  <table style="border-collapse:collapse">${rows}</table>
  <p>Total on the waitlist: <strong>${total}</strong></p>
  <p style="color:#6b5560;font-size:13px">These people asked to be told when
  Venttly launches. They have not agreed to anything else.</p>
</div>`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const auth = verifyInternalSecret(req, {
    envName: "CRON_SECRET",
    headerName: "x-cron-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM_ADDRESS") ?? "hello@venttly.app";
  const to = Deno.env.get("WAITLIST_DIGEST_TO") ?? DEFAULT_TO;
  if (!apiKey) return json({ error: "resend_not_configured" }, 503);

  const db = adminClient();

  // Counted before the claim so the total is never missing from a report that
  // did go out.
  const { data: totalData, error: totalError } = await db.rpc("waitlist_total");
  if (totalError) {
    console.error("waitlist.total_failed", totalError.message);
    return json({ error: "total_failed" }, 500);
  }
  const total = Number(totalData ?? 0);

  const { data, error } = await db.rpc("claim_waitlist_digest");
  if (error) {
    console.error("waitlist.claim_failed", error.message);
    return json({ error: "claim_failed" }, 500);
  }
  const signups = (data ?? []) as Signup[];

  // A quiet day sends nothing. The alternative -- a daily "0 new" mail -- is
  // the kind of message people filter, and a filtered digest is a digest
  // nobody reads on the day it matters.
  if (signups.length === 0) {
    return json({ ok: true, sent: 0, total, skipped: "no_new_signups" });
  }

  const subject = `Venttly waitlist — ${signups.length} new (${total} total)`;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: [to],
      subject,
      text: textBody(signups, total),
      html: htmlBody(signups, total),
    }),
  });

  if (!res.ok) {
    // The rows are already stamped, so this is the one failure that costs
    // something. Logged with the addresses so the day is recoverable from the
    // function log without a database query.
    const detail = await res.text();
    console.error(
      "waitlist.send_failed",
      res.status,
      detail,
      signups.map((s) => s.email).join(","),
    );
    return json({ error: "send_failed", status: res.status }, 502);
  }

  return json({ ok: true, sent: signups.length, total });
});
