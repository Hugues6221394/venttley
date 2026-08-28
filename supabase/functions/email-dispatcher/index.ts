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

const TEMPLATES: Record<string, Template> = {
  welcome: {
    subject: () => "Welcome to Venttly",
    html: (v) =>
      `<p>Hey @${htmlValue(v.pseudonym, "there")},</p>
      <p>Welcome to Venttly — an anonymous space to share what you can't post elsewhere.</p>
      <p>You're all set. <a href="https://venttly.app">Open the app</a> any time.</p>
      <p>— The Venttly team</p>`,
    text: (v) =>
      `Hey @${plainValue(v.pseudonym, "there")},

Welcome to Venttly — an anonymous space to share what you can't post elsewhere.

You're all set. Open the app any time: https://venttly.app

— The Venttly team`,
  },
  verify_email: {
    subject: () => "Your Venttly verification code",
    html: (v) =>
      v.code
        ? `<p>Hi,</p>
      <p>Enter this code in the app to verify your email:</p>
      <p style="font-size:28px;font-weight:800;letter-spacing:6px;margin:16px 0;">${
          htmlValue(v.code, "", 64)
        }</p>
      <p>It expires in 15 minutes. If you didn't request it, ignore this message.</p>
      <p>— The Venttly team</p>`
        : `<p>Hi,</p>
      <p>Tap the link to verify your email:</p>
      <p><a href="${
          htmlValue(safeHttpsUrl(v.confirm_url), "https://venttly.app", 2000)
        }">Verify email</a></p>
      <p>If you didn't sign up, ignore this message.</p>`,
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
  password_reset: {
    subject: () => "Reset your Venttly password",
    html: (v) =>
      `<p>Use this link within 1 hour to set a new password:</p>
      <p><a href="${
        htmlValue(safeHttpsUrl(v.reset_url), "https://venttly.app", 2000)
      }">Reset password</a></p>`,
    text: (v) =>
      `Use this link within 1 hour to set a new password:
${safeHttpsUrl(v.reset_url)}

If you didn't request this, you can safely ignore it.`,
  },
  security_alert: {
    subject: (v) =>
      `New sign-in to your Venttly account from ${
        plainValue(v.device, "a new device", 100)
      }`,
    html: (v) =>
      `<p>We noticed a new sign-in:</p>
      <ul>
        <li>Device: ${htmlValue(v.device, "unknown", 100)}</li>
        <li>When: ${htmlValue(v.when, "just now", 100)}</li>
        <li>Location (approx): ${htmlValue(v.location, "unknown", 100)}</li>
      </ul>
      <p>If this wasn't you, change your password immediately.</p>`,
    text: (v) =>
      `We noticed a new sign-in:

- Device: ${plainValue(v.device, "unknown", 100)}
- When: ${plainValue(v.when, "just now", 100)}
- Location (approx): ${plainValue(v.location, "unknown", 100)}

If this wasn't you, change your password immediately.`,
  },
  weekly_digest: {
    subject: () => "Your Venttly week — stories you might have missed",
    html: (v) =>
      `<p>Here's what's been brewing:</p>
      <ul>
        <li>${htmlValue(v.hugs_received, "0", 20)} hugs received</li>
        <li>${htmlValue(v.new_friends, "0", 20)} new friends</li>
        <li>${htmlValue(v.top_post_title, "Open the app to see what hit")}</li>
      </ul>`,
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
  const recipient = await supabase.auth.admin.getUserById(delivery.user_id);
  if (recipient.error) {
    await complete(supabase, delivery, "retry", "recipient_lookup_failed");
    return "retried";
  }
  const to = recipient.data.user?.email;
  if (!to || to.endsWith("@id.venttly.app")) {
    await complete(supabase, delivery, "skipped", "no_real_email");
    return "skipped";
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
