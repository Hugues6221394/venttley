// email-dispatcher
//
// Drains `email_outbox` and sends through Resend. Invoked by the pg_cron
// drain job (migration 0077) every minute, or by a Database Webhook on
// email_outbox INSERT for instant sends. Either caller must present the
// shared internal-cron secret:
//   x-cron-secret: <CRON_SECRET>
// JWT verification is OFF (config.toml) so the public anon key can't drain
// the queue — the secret is the only way in. (If you add a dashboard
// Database Webhook later, give it the same x-cron-secret header.)
//
// Env:
//   CRON_SECRET           — required; shared gate (same value as account-purge)
//   RESEND_API_KEY        — Resend API key
//   RESEND_FROM_ADDRESS   — verified sender (e.g. hello@venttly.app)
//   RESEND_REPLY_TO       — optional monitored reply address
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
//
// Templates live in code below — keep them short and brand-aligned.
// For richer HTML, swap to MJML compiled at build time.

import { adminClient } from "../_shared/supabase.ts";
import {
  rolloutEnabled,
  verifyInternalSecret,
} from "../_shared/internal_auth.ts";

interface Template {
  subject: (vars: Record<string, unknown>) => string;
  html: (vars: Record<string, unknown>) => string;
  // Plain-text alternative. Every email ships multipart (text + html):
  // text-only clients render it, and spam filters score HTML-only mail as
  // more suspicious, so a real text part improves inbox placement.
  text: (vars: Record<string, unknown>) => string;
}

interface EmailDelivery {
  outbox_id: string;
  user_id: string;
  template: string;
  variables: Record<string, unknown> | null;
  attempts: number;
  /** Explicit recipient; null means resolve from the account. */
  to_address: string | null;
}

function plainValue(
  value: unknown,
  fallback: string,
  maxLength = 300,
): string {
  const text = typeof value === "string" || typeof value === "number"
    ? String(value)
    : fallback;
  return text.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, maxLength);
}

function htmlValue(value: unknown, fallback: string, maxLength = 300): string {
  return plainValue(value, fallback, maxLength)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function safeHttpsUrl(value: unknown): string {
  const raw = plainValue(value, "", 2000);
  try {
    const parsed = new URL(raw);
    return parsed.protocol === "https:"
      ? parsed.toString()
      : "https://venttly.app";
  } catch {
    return "https://venttly.app";
  }
}


// ── brand ──────────────────────────────────────────────────────────────────
//
// Venttly's palette, from lib/presentation/theme/colors.dart. Kept as literals
// rather than imported: this runs in Deno on Supabase's edge, nowhere near the
// Flutter app, and a colour drifting is a far smaller problem than a build
// that cannot resolve a Dart file.
const BRAND = {
  berry: "#E0245E",
  deep: "#A81145",
  blush: "#FDF8FA",
  tint: "#FBE9F0",
  mauve: "#F3E4EA",
  ink: "#241118",
  muted: "#7A6269",
};

// Optional. Mail clients block remote images by default — Outlook and a good
// share of Gmail accounts show nothing at all — so the wordmark below is real
// text, and the logo is an enhancement rather than the brand. Set
// BRAND_LOGO_URL to a public https image and it appears above the wordmark;
// leave it unset and the email is unchanged in every way that matters.
const LOGO_URL = Deno.env.get("BRAND_LOGO_URL") ?? "";

const APP_URL = "https://venttly.app";

/// One shell for every branded email, so the colours and the footer live once.
///
/// Tables, inline styles and no shorthand CSS. That is not nostalgia: Outlook
/// renders through Word, which ignores float, flexbox, border-radius and most
/// of what a stylesheet would carry. What survives everywhere is a table with
/// inline attributes, so that is what this is.
function shell(options: {
  preheader: string;
  heading: string;
  body: string;
  cta?: { label: string; href: string };
  /// Why this landed in their inbox. Per-template, because "somebody created
  /// an account with this address" is true of a welcome and plainly false of a
  /// security alert — and a footer that explains the wrong thing is worse than
  /// one that explains nothing, on mail about somebody's account being
  /// accessed.
  reason?: string;
}): string {
  const logo = LOGO_URL
    ? `<img src="${LOGO_URL}" width="110" alt="Venttly"
           style="display:block;margin:0 auto 10px;border:0;outline:none;text-decoration:none;" />`
    : "";
  const cta = options.cta
    ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:26px auto 6px;">
         <tr><td align="center" bgcolor="${BRAND.berry}" style="border-radius:28px;">
           <a href="${options.cta.href}"
              style="display:inline-block;padding:14px 34px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:28px;">
             ${options.cta.label}
           </a>
         </td></tr>
       </table>`
    : "";

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="color-scheme" content="light" />
<title>Venttly</title>
</head>
<body style="margin:0;padding:0;background:${BRAND.blush};">
  <!-- The line shown beside the subject in an inbox list. Hidden in the body. -->
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;">${options.preheader}</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BRAND.blush};">
    <tr><td align="center" style="padding:32px 16px;">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"
             style="width:100%;max-width:600px;background:#ffffff;border:1px solid ${BRAND.mauve};border-radius:20px;">
        <tr><td align="center" style="padding:34px 32px 6px;">
          ${logo}
          <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:30px;font-weight:800;letter-spacing:-0.4px;color:${BRAND.berry};">Venttly</div>
        </td></tr>
        <tr><td style="padding:18px 32px 0;">
          <h1 style="margin:0 0 14px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:23px;line-height:1.3;font-weight:800;color:${BRAND.ink};">${options.heading}</h1>
          ${options.body}
          ${cta}
        </td></tr>
        <tr><td style="padding:26px 32px 30px;">
          <div style="height:1px;background:${BRAND.mauve};line-height:1px;font-size:0;">&nbsp;</div>
          <p style="margin:18px 0 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;color:${BRAND.muted};">
            ${
    options.reason ??
      "You are receiving this because you have a Venttly account."
  }
          </p>
          <p style="margin:10px 0 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;color:${BRAND.muted};">
            Venttly is made by CODAFRIQA LTD.
          </p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;
}

const P =
  `margin:0 0 14px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.65;color:${BRAND.ink};`;

const SMALL =
  `margin:0 0 12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.6;color:${BRAND.muted};`;

/// A one-time code, set to be read aloud off a screen and typed into a phone.
function codeBlock(code: string): string {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:6px 0 18px;">
    <tr><td align="center" style="background:${BRAND.tint};border-radius:14px;padding:20px 12px;">
      <div style="font-family:'SF Mono',SFMono-Regular,Menlo,Consolas,monospace;font-size:30px;font-weight:700;letter-spacing:9px;color:${BRAND.deep};">${code}</div>
    </td></tr>
  </table>`;
}

/// One labelled fact per row — device, time, place.
function factRows(rows: Array<[string, string]>): string {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:2px 0 16px;">
    ${
    rows.map(([k, v]) =>
      `<tr>
         <td style="padding:5px 12px 5px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;color:${BRAND.muted};white-space:nowrap;">${k}</td>
         <td style="padding:5px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:14px;font-weight:600;color:${BRAND.ink};">${v}</td>
       </tr>`
    ).join("")
  }
  </table>`;
}

const TEMPLATES: Record<string, Template> = {
  welcome: {
    subject: () => "Welcome to Venttly",
    html: (v) =>
      shell({
        preheader: "You're in. Here's the one rule that actually matters.",
        heading: `You're in, @${htmlValue(v.pseudonym, "friend", 60)}.`,
        body:
          `<p style="${P}">Venttly is for the things you cannot post anywhere else — with your name off them. No one here needs to know who you are to understand you.</p>
           <p style="${P}">Things worth trying first:</p>
           <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 16px;">
             <tr><td style="padding:3px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;color:${BRAND.ink};">
               <strong style="color:${BRAND.deep};">Vent it out.</strong> Say it plainly. Nobody is grading you.</td></tr>
             <tr><td style="padding:3px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;color:${BRAND.ink};">
               <strong style="color:${BRAND.deep};">Spill and scroll.</strong> Sit with other people's days for a while.</td></tr>
             <tr><td style="padding:3px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;color:${BRAND.ink};">
               <strong style="color:${BRAND.deep};">Find your tribe.</strong> Spaces for whatever you are carrying.</td></tr>
           </table>
           <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:4px 0 2px;">
             <tr><td style="background:${BRAND.tint};border-radius:14px;padding:18px 20px;">
               <p style="margin:0 0 8px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;font-weight:800;letter-spacing:0.6px;text-transform:uppercase;color:${BRAND.deep};">The one rule</p>
               <p style="margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.65;color:${BRAND.ink};">
                 People arrive here on their worst days. Treat whoever is on the other side the way you would want to be treated on yours — with kindness, and with real care for what they have trusted you with. That is the whole thing.
               </p>
             </td></tr>
           </table>`,
        cta: { label: "Open Venttly", href: APP_URL },
        reason:
          "You are getting this because somebody created a Venttly account with this address. " +
          "If that was not you, you can ignore this message and nothing more will be sent.",
      }),
    text: (v) =>
      `You're in, @${plainValue(v.pseudonym, "friend", 60)}.

Venttly is for the things you cannot post anywhere else — with your name off
them. No one here needs to know who you are to understand you.

Things worth trying first:
  Vent it out.     Say it plainly. Nobody is grading you.
  Spill and scroll. Sit with other people's days for a while.
  Find your tribe. Spaces for whatever you are carrying.

THE ONE RULE
People arrive here on their worst days. Treat whoever is on the other side the
way you would want to be treated on yours — with kindness, and with real care
for what they have trusted you with. That is the whole thing.

Open Venttly: ${APP_URL}

You are getting this because somebody created a Venttly account with this
address. If that was not you, you can ignore this message.

Venttly is made by CODAFRIQA LTD.`,
  },
  verify_email: {
    subject: () => "Your Venttly verification code",
    html: (v) =>
      v.code
        ? shell({
          preheader: "Your code expires in 15 minutes.",
          heading: "Confirm your email",
          body: `<p style="${P}">Enter this code in the app:</p>
                 ${codeBlock(htmlValue(v.code, "", 64))}
                 <p style="${SMALL}">It expires in 15 minutes. If you did not ask for it, ignore this message — nothing happens without the code.</p>`,
          reason: "You are receiving this because this address was entered on a Venttly account.",
        })
        : shell({
          preheader: "One tap to confirm your email.",
          heading: "Confirm your email",
          body: `<p style="${P}">Tap the button to confirm this address belongs to you.</p>
                 <p style="${SMALL}">If you did not sign up for Venttly, ignore this message.</p>`,
          cta: { label: "Verify email", href: safeHttpsUrl(v.confirm_url) },
          reason: "You are receiving this because this address was entered on a Venttly account.",
        }),
    text: (v) =>
      v.code
        ? `Hi,

Enter this code in the app to verify your email:

${plainValue(v.code, "", 64)}

It expires in 15 minutes. If you didn't request it, ignore this message.

— The Venttly team`
        : `Hi,

Verify your email by opening this link:
${safeHttpsUrl(v.confirm_url)}

If you didn't sign up, ignore this message.`,
  },
  // Code first, link second. The reset is driven from inside the app, so a
  // link would have to deep-link back into it — one more thing to break on a
  // device where the app is not the default handler. The link branch stays for
  // any caller still queueing reset_url.
  password_reset: {
    subject: () => "Your Venttly password reset code",
    html: (v) =>
      v.code
        ? shell({
          preheader: "Your reset code expires in 15 minutes.",
          heading: "Set a new password",
          body: `<p style="${P}">Enter this code in the app:</p>
                 ${codeBlock(htmlValue(v.code, "", 64))}
                 <p style="${SMALL}">It expires in 15 minutes. If you did not ask to reset your password, ignore this message — nothing has changed, and nobody can change it without this code.</p>`,
          reason: "You are receiving this because a password reset was requested for your Venttly account.",
        })
        : shell({
          preheader: "Set a new password within the hour.",
          heading: "Set a new password",
          body: `<p style="${P}">Use the button below within the next hour.</p>
                 <p style="${SMALL}">If you did not request this, you can safely ignore it — nothing has changed.</p>`,
          cta: { label: "Reset password", href: safeHttpsUrl(v.reset_url) },
          reason: "You are receiving this because a password reset was requested for your Venttly account.",
        }),
    text: (v) =>
      v.code
        ? `Hi,

Enter this code in the app to set a new password:

${plainValue(v.code, "", 64)}

It expires in 15 minutes. If you didn't ask to reset your password, ignore this
message — nothing has changed.

— The Venttly team`
        : `Use this link within 1 hour to set a new password:
${safeHttpsUrl(v.reset_url)}

If you didn't request this, you can safely ignore it.`,
  },
  security_alert: {
    subject: (v) =>
      `New sign-in to your Venttly account from ${
        plainValue(v.device, "a new device", 100)
      }`,
    html: (v) =>
      shell({
        preheader: "If this was not you, change your password now.",
        heading: "A new sign-in to your account",
        body: `<p style="${P}">Somebody signed in to your Venttly account:</p>
               ${
          factRows([
            ["Device", htmlValue(v.device, "unknown", 100)],
            ["When", htmlValue(v.when, "just now", 100)],
            ["Location", htmlValue(v.location, "unknown", 100)],
          ])
        }
               <p style="${P}">If that was you, there is nothing to do. If it was not, change your password now — and check Profile → Password &amp; security, where every device and sign-in is listed.</p>`,
        reason: "Security notices like this one are always sent, and cannot be switched off.",
      }),
    text: (v) =>
      `We noticed a new sign-in:

- Device: ${plainValue(v.device, "unknown", 100)}
- When: ${plainValue(v.when, "just now", 100)}
- Location (approx): ${plainValue(v.location, "unknown", 100)}

If this wasn't you, change your password immediately.`,
  },
  // Account changes rather than sign-ins: a password rotation, two-factor
  // being switched off, a device the user just blocked. security_alert is
  // shaped around "we saw a sign-in" and reads as a non-sequitur for these,
  // so they get their own headline/detail pair supplied by the caller.
  security_account_change: {
    subject: (v) =>
      `Venttly security: ${plainValue(v.headline, "an account change", 120)}`,
    html: (v) =>
      shell({
        preheader: plainValue(v.headline, "A change on your account", 120),
        heading: htmlValue(v.headline, "Something changed on your account", 120),
        body: `<p style="${P}">${
          htmlValue(v.detail, "Open the app to review your recent activity.", 400)
        }</p>
               ${factRows([["When", htmlValue(v.when, "just now", 100)]])}
               <p style="${SMALL}">Every device and security event is listed in the app under Profile → Password &amp; security. If you did not make this change, go there now.</p>`,
        reason: "Security notices like this one are always sent, and cannot be switched off.",
      }),
    text: (v) =>
      `${plainValue(v.headline, "Something changed on your account", 120)}

${plainValue(v.detail, "Open the app to review your recent activity.", 400)}

When: ${plainValue(v.when, "just now", 100)}

You can review every device and security event in the app under
Profile > Password & security.`,
  },
  weekly_digest: {
    subject: () => "Your Venttly week — stories you might have missed",
    html: (v) =>
      shell({
        preheader: "Hugs, new friends, and the one that landed.",
        heading: "Your week on Venttly",
        body: `${
          factRows([
            ["Hugs received", htmlValue(v.hugs_received, "0", 20)],
            ["New friends", htmlValue(v.new_friends, "0", 20)],
          ])
        }
               <p style="${P}"><strong style="color:${BRAND.deep};">The one that landed:</strong> ${
          htmlValue(v.top_post_title, "Open the app to see what hit")
        }</p>`,
        cta: { label: "Open Venttly", href: APP_URL },
        reason:
          "You are receiving your weekly summary. Turn it off any time in the app under Settings → Notifications.",
      }),
    text: (v) =>
      `Here's what's been brewing:

- ${plainValue(v.hugs_received, "0", 20)} hugs received
- ${plainValue(v.new_friends, "0", 20)} new friends
- ${plainValue(v.top_post_title, "Open the app to see what hit")}

Open the app: https://venttly.app`,
  },
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = verifyInternalSecret(req, {
    envName: "CRON_SECRET",
    headerName: "x-cron-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (!rolloutEnabled("EMAIL_DELIVERY_ENABLED")) {
    return json({ ok: false, disabled: true }, 503);
  }

  const apiKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM_ADDRESS") ?? "hello@venttly.app";
  const replyTo = Deno.env.get("RESEND_REPLY_TO") ?? undefined;
  if (!apiKey) {
    return json({ error: "resend_not_configured" }, 503);
  }
  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const batch = clamp(
    typeof body?.batch === "number" ? body.batch : 25,
    1,
    100,
  );
  const supabase = adminClient();
  const claimed = await supabase.rpc("claim_email_deliveries", {
    p_batch: batch,
  });
  if (claimed.error) return json({ error: "email_claim_failed" }, 500);
  const deliveries = (claimed.data ?? []) as EmailDelivery[];

  const counts = { sent: 0, skipped: 0, retried: 0, failed: 0 };
  await runPool(deliveries, 5, async (delivery) => {
    const outcome = await deliverOne(
      supabase,
      delivery,
      apiKey,
      from,
      replyTo,
    );
    counts[outcome]++;
  });
  return json({ ok: true, claimed: deliveries.length, ...counts });
});

async function deliverOne(
  supabase: ReturnType<typeof adminClient>,
  delivery: EmailDelivery,
  apiKey: string,
  from: string,
  replyTo?: string,
): Promise<"sent" | "skipped" | "retried" | "failed"> {
  const template = TEMPLATES[delivery.template];
  if (!template) {
    await complete(supabase, delivery, "failed", "unknown_template");
    return "failed";
  }
  // An explicit recipient wins and skips the auth lookup entirely. This is how
  // a recovery address gets verified: the whole point is to mail somewhere the
  // account does not yet own, so resolving from auth.users.email would defeat
  // it. Only SECURITY DEFINER callers can set the column — clients have no
  // INSERT privilege on email_outbox — and a CHECK constraint refuses the
  // synthetic domain there.
  let to = delivery.to_address ?? null;

  if (!to) {
    const recipient = await supabase.auth.admin.getUserById(delivery.user_id);
    if (recipient.error) {
      await complete(supabase, delivery, "retry", "recipient_lookup_failed");
      return "retried";
    }
    to = recipient.data.user?.email ?? null;
    if (!to || to.endsWith("@id.venttly.app")) {
      // Every anonymous account has a synthetic address, so this is the normal
      // outcome for them rather than an error — and it is why nothing queued
      // without an explicit recipient has ever reached one.
      await complete(supabase, delivery, "skipped", "no_real_email");
      return "skipped";
    }
  }

  const variables = delivery.variables ?? {};
  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `email-outbox-${delivery.outbox_id}`,
      },
      body: JSON.stringify({
        from,
        to: [to],
        ...(replyTo ? { reply_to: replyTo } : {}),
        subject: template.subject(variables),
        html: template.html(variables),
        text: template.text(variables),
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (response.ok) {
      await complete(supabase, delivery, "sent", null);
      return "sent";
    }
    const retryable = response.status === 409 || response.status === 429 ||
      response.status >= 500;
    await complete(
      supabase,
      delivery,
      retryable ? "retry" : "failed",
      `resend_http_${response.status}`,
    );
    return retryable ? "retried" : "failed";
  } catch {
    await complete(supabase, delivery, "retry", "resend_network_error");
    return "retried";
  }
}

async function complete(
  supabase: ReturnType<typeof adminClient>,
  delivery: EmailDelivery,
  outcome: "sent" | "skipped" | "retry" | "failed",
  error: string | null,
): Promise<void> {
  const result = await supabase.rpc("complete_email_delivery", {
    p_outbox_id: delivery.outbox_id,
    p_attempt: delivery.attempts,
    p_outcome: outcome,
    p_error_code: error,
  });
  if (result.error) console.error("email completion failed", "database_error");
}

async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      while (next < items.length) await worker(items[next++]);
    },
  );
  await Promise.all(runners);
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(Math.trunc(value), minimum), maximum);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
