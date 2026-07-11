// geo-capture
//
// Records the COARSE country (ISO-3166 alpha-2) a signed-in user is connecting
// from, so the admin analytics "where users come from" is real rather than
// only self-reported home_country. The mobile client pings this once per
// session, fire-and-forget.
//
// Privacy by design:
//   * We resolve country ONLY. The IP address is never stored — it is read
//     from the request, mapped to a country, and discarded.
//   * No city, no precise location, no lat/long. This is for aggregate
//     analytics, not for locating anyone. (See the safety policy: Venttly does
//     not do covert user geolocation.)
//
// Country resolution order:
//   1. Edge/CDN-provided country header (cf-ipcountry / x-vercel-ip-country) —
//      free, no external call.
//   2. ipinfo.io/{ip}/country when IPINFO_TOKEN is set (50k lookups/mo free,
//      scales cleanly). Preferred once you outgrow the anonymous tier.
//   3. Fallback: ipapi.co/{ip}/country/ (anonymous, ~1k/day — fine to start).
//
// Auth: JWT verification ON (default). The caller's own token identifies the
// user; we update only that user's row via the service-role client.
//
// Env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (auto-set).
//      IPINFO_TOKEN (optional) — set to use ipinfo.io instead of ipapi.co.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

function firstIp(fwd: string | null): string | null {
  if (!fwd) return null;
  const ip = fwd.split(',')[0]?.trim();
  return ip && ip.length > 0 ? ip : null;
}

function isoCountry(v: string | null): string | null {
  if (!v) return null;
  const c = v.trim().toUpperCase();
  return /^[A-Z]{2}$/.test(c) ? c : null;
}

async function lookup(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(2500) });
    if (!res.ok) return null;
    return isoCountry(await res.text());
  } catch {
    return null; // A provider outage never breaks the request.
  }
}

async function resolveCountry(req: Request): Promise<string | null> {
  // 1) CDN header, if the deployment sits behind one.
  const header =
    isoCountry(req.headers.get('cf-ipcountry')) ??
    isoCountry(req.headers.get('x-vercel-ip-country'));
  if (header) return header;

  // 2/3) External lookup on the forwarded IP.
  const ip = firstIp(req.headers.get('x-forwarded-for'));
  if (!ip) return null;

  const token = Deno.env.get('IPINFO_TOKEN');
  if (token) {
    const c = await lookup(`https://ipinfo.io/${ip}/country?token=${token}`);
    if (c) return c;
  }
  return lookup(`https://ipapi.co/${ip}/country/`);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;
  const headers = { ...corsHeaders, 'Content-Type': 'application/json' };

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ ok: false, error: 'no auth' }), {
      status: 401,
      headers,
    });
  }

  // Identify the caller from their own token.
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) {
    return new Response(JSON.stringify({ ok: false, error: 'invalid token' }), {
      status: 401,
      headers,
    });
  }

  const country = await resolveCountry(req);
  if (!country) {
    // Nothing to record — not an error, just no signal this session.
    return new Response(JSON.stringify({ ok: true, country: null }), { headers });
  }

  const sb = adminClient();
  const { error } = await sb
    .from('users')
    .update({ last_country: country, last_country_at: new Date().toISOString() })
    .eq('user_id', user.id);

  if (error) {
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500,
      headers,
    });
  }
  return new Response(JSON.stringify({ ok: true, country }), { headers });
});
