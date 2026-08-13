// geo-capture
//
// Records the COARSE country (ISO-3166 alpha-2) a signed-in user is connecting
// from, so the admin analytics "where users come from" is real rather than
// only self-reported home_country. The mobile client pings this once per
// session, fire-and-forget.
//
// Privacy by design:
//   * We resolve country ONLY. The deployment edge maps the connection to a
//     country header; this function never reads, stores, or forwards a raw IP.
//   * No city, no precise location, no lat/long. This is for aggregate
//     analytics, not for locating anyone. (See the safety policy: Venttly does
//     not do covert user geolocation.)
//
// Country is accepted only from deployment-edge geolocation headers and is
// analytics input, never an authorization or fraud signal. This function makes
// no IP-geolocation request to another processor.
//
// Auth: JWT verification ON (default). The caller's own token identifies the
// user; we update only that user's row via the service-role client.
//
// Env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (auto-set).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { adminClient } from "../_shared/supabase.ts";
import { corsHeaders, handleOptions } from "../_shared/cors.ts";

function isoCountry(v: string | null): string | null {
  if (!v) return null;
  const c = v.trim().toUpperCase();
  return /^[A-Z]{2}$/.test(c) ? c : null;
}

function resolveCountry(req: Request): string | null {
  return (
    isoCountry(req.headers.get("cf-ipcountry")) ??
      isoCountry(req.headers.get("x-vercel-ip-country"))
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions()!;
  const headers = { ...corsHeaders, "Content-Type": "application/json" };

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ ok: false, error: "no auth" }), {
      status: 401,
      headers,
    });
  }

  // Identify the caller from their own token.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY") ??
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) {
    return new Response(JSON.stringify({ ok: false, error: "invalid token" }), {
      status: 401,
      headers,
    });
  }

  const country = resolveCountry(req);
  if (!country) {
    // Nothing to record — not an error, just no signal this session.
    return new Response(JSON.stringify({ ok: true, country: null }), {
      headers,
    });
  }

  const sb = adminClient();
  const { error } = await sb
    .from("users")
    .update({
      last_country: country,
      last_country_at: new Date().toISOString(),
    })
    .eq("user_id", user.id);

  if (error) {
    return new Response(
      JSON.stringify({ ok: false, error: "country_update_failed" }),
      {
        status: 500,
        headers,
      },
    );
  }
  return new Response(JSON.stringify({ ok: true, country }), { headers });
});
