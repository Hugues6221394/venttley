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

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

interface Template {
  subject: (vars: Record<string, unknown>) => string;
  html:    (vars: Record<string, unknown>) => string;
  // Plain-text alternative. Every email ships multipart (text + html):
  // text-only clients render it, and spam filters score HTML-only mail as
  // more suspicious, so a real text part improves inbox placement.
  text:    (vars: Record<string, unknown>) => string;
}

const TEMPLATES: Record<string, Template> = {
  welcome: {
    subject: () => 'Welcome to Venttly',
    html: (v) => `<p>Hey @${v.pseudonym ?? 'there'},</p>
      <p>Welcome to Venttly — an anonymous space to share what you can't post elsewhere.</p>
      <p>You're all set. <a href="https://venttly.app">Open the app</a> any time.</p>
      <p>— The Venttly team</p>`,
    text: (v) => `Hey @${v.pseudonym ?? 'there'},

Welcome to Venttly — an anonymous space to share what you can't post elsewhere.

You're all set. Open the app any time: https://venttly.app

— The Venttly team`,
  },
  verify_email: {
    subject: () => 'Your Venttly verification code',
    html: (v) => v.code
      ? `<p>Hi,</p>
      <p>Enter this code in the app to verify your email:</p>
      <p style="font-size:28px;font-weight:800;letter-spacing:6px;margin:16px 0;">${v.code}</p>
      <p>It expires in 15 minutes. If you didn't request it, ignore this message.</p>
      <p>— The Venttly team</p>`
      : `<p>Hi,</p>
      <p>Tap the link to verify your email:</p>
      <p><a href="${v.confirm_url}">Verify email</a></p>
      <p>If you didn't sign up, ignore this message.</p>`,
    text: (v) => v.code
      ? `Hi,

Enter this code in the app to verify your email:

${v.code}

It expires in 15 minutes. If you didn't request it, ignore this message.

— The Venttly team`
      : `Hi,

Verify your email by opening this link:
${v.confirm_url}

If you didn't sign up, ignore this message.`,
  },
  password_reset: {
    subject: () => 'Reset your Venttly password',
    html: (v) => `<p>Use this link within 1 hour to set a new password:</p>
      <p><a href="${v.reset_url}">Reset password</a></p>`,
    text: (v) => `Use this link within 1 hour to set a new password:
${v.reset_url}

If you didn't request this, you can safely ignore it.`,
  },
  security_alert: {
    subject: (v) => `New sign-in to your Venttly account from ${v.device ?? 'a new device'}`,
    html: (v) => `<p>We noticed a new sign-in:</p>
      <ul>
        <li>Device: ${v.device ?? 'unknown'}</li>
        <li>When: ${v.when ?? 'just now'}</li>
        <li>Location (approx): ${v.location ?? 'unknown'}</li>
      </ul>
      <p>If this wasn't you, change your password immediately.</p>`,
    text: (v) => `We noticed a new sign-in:

- Device: ${v.device ?? 'unknown'}
- When: ${v.when ?? 'just now'}
- Location (approx): ${v.location ?? 'unknown'}

If this wasn't you, change your password immediately.`,
  },
  weekly_digest: {
    subject: () => 'Your Venttly week — stories you might have missed',
    html: (v) => `<p>Here's what's been brewing:</p>
      <ul>
        <li>${v.hugs_received ?? 0} hugs received</li>
        <li>${v.new_friends ?? 0} new friends</li>
        <li>${v.top_post_title ?? 'Open the app to see what hit'}</li>
      </ul>`,
    text: (v) => `Here's what's been brewing:

- ${v.hugs_received ?? 0} hugs received
- ${v.new_friends ?? 0} new friends
- ${v.top_post_title ?? 'Open the app to see what hit'}

Open the app: https://venttly.app`,
  },
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;

  // --- Auth gate: shared secret, timing-safe compare -------------------
  const expected = Deno.env.get('CRON_SECRET');
  if (!expected) {
    return new Response('CRON_SECRET not configured', { status: 500, headers: corsHeaders });
  }
  if (!secretsMatch(req.headers.get('x-cron-secret') ?? '', expected)) {
    return new Response('unauthorized', { status: 401, headers: corsHeaders });
  }

  const supabase = adminClient();

  const apiKey = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('RESEND_FROM_ADDRESS') ?? 'hello@venttly.app';
  const replyTo = Deno.env.get('RESEND_REPLY_TO') ?? undefined;
  if (!apiKey) {
    return new Response('RESEND_API_KEY not set', { status: 500, headers: corsHeaders });
  }

  // Pull up to 25 queued rows. The Status update is RLS-bypassed since
  // we're on service role.
  const { data: rows, error } = await supabase
    .from('email_outbox')
    .select('outbox_id, user_id, template, variables, attempts')
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(25);
  if (error) {
    return new Response(error.message, { status: 500, headers: corsHeaders });
  }
  if (!rows || rows.length === 0) {
    return new Response('empty', { headers: corsHeaders });
  }

  let sent = 0;
  let failed = 0;
  for (const row of rows) {
    const tmpl = TEMPLATES[row.template];
    if (!tmpl) {
      await mark(supabase, row.outbox_id, 'failed', `unknown template: ${row.template}`);
      failed++;
      continue;
    }
    // Resolve recipient email. Lives on auth.users.email — accessed via
    // the user_id link inside Supabase's auth schema.
    const { data: authUser } = await supabase.auth.admin.getUserById(row.user_id);
    const to = authUser?.user?.email;
    if (!to || to.endsWith('@id.venttly.app')) {
      // Synthetic anonymous-handle emails don't receive mail.
      await mark(supabase, row.outbox_id, 'skipped', 'no real email');
      continue;
    }

    try {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from,
          to: [to],
          ...(replyTo ? { reply_to: replyTo } : {}),
          subject: tmpl.subject(row.variables ?? {}),
          html: tmpl.html(row.variables ?? {}),
          text: tmpl.text(row.variables ?? {}),
        }),
      });
      if (res.ok) {
        await mark(supabase, row.outbox_id, 'sent');
        sent++;
      } else {
        const text = await res.text();
        await mark(supabase, row.outbox_id, 'failed', text.slice(0, 500));
        failed++;
      }
    } catch (e) {
      await mark(supabase, row.outbox_id, 'failed', String(e).slice(0, 500));
      failed++;
    }
  }

  return new Response(JSON.stringify({ sent, failed }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});

/// Length-safe equality that doesn't early-return on the first mismatched
/// byte, to avoid leaking the secret via timing.
function secretsMatch(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function mark(
  client: ReturnType<typeof adminClient>,
  id: string,
  status: 'sent' | 'failed' | 'skipped',
  err?: string,
) {
  await client
    .from('email_outbox')
    .update({
      status,
      sent_at: status === 'sent' ? new Date().toISOString() : null,
      last_error: err ?? null,
    })
    .eq('outbox_id', id);
}
