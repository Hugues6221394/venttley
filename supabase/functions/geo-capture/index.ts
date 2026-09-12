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

// Country headers, in order of trust. Which of these exists depends entirely
// on what sits in front of the function, and live testing showed this
// deployment sets NONE of the original two — geo-capture answered
// {"ok":true,"country":null} for every real user, so users.last_country stayed
// empty and the risk engine's new-country signal could never fire.
//
// Listing the candidates costs nothing and means the function starts working
// the moment an edge that sets one of them is in front of it. COUNTRY_HEADER
// lets an operator name a header explicitly without another deploy.
const COUNTRY_HEADERS = [
  "cf-ipcountry", // Cloudflare
  "x-vercel-ip-country", // Vercel
  "x-nf-client-connection-country", // Netlify
  "fly-client-country", // Fly.io
  "x-appengine-country", // Google
  "x-geo-country",
  "x-country-code",
  "x-client-country",
];

function resolveCountry(req: Request): string | null {
  const named = Deno.env.get("COUNTRY_HEADER");
  if (named) {
    const v = isoCountry(req.headers.get(named));
    if (v) return v;
  }
  for (const h of COUNTRY_HEADERS) {
    const v = isoCountry(req.headers.get(h));
    if (v) return v;
  }
  return null;
}

// Which country-ish headers this deployment actually provides, by NAME only.
// Values are never returned: a header value can be an IP, and this function
// exists precisely so IPs are not handled. Without this the only way to learn
// what the edge supplies is to guess and redeploy.
function presentCountryHeaders(req: Request): string[] {
  const seen: string[] = [];
  for (const [name] of req.headers) {
    const n = name.toLowerCase();
    if (n.includes("country") || n.includes("geo") || n.includes("ipcountry")) {
      seen.push(n);
    }
  }
  return seen.sort();
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
  const debug = new URL(req.url).searchParams.get("debug") === "headers";

  if (!country) {
    // Nothing to record — not an error, just no signal this session. When
    // asked, say which country headers the edge did supply so the gap can be
    // diagnosed without another deploy.
    return new Response(
      JSON.stringify({
        ok: true,
        country: null,
        ...(debug ? { country_headers_present: presentCountryHeaders(req) } : {}),
      }),
      { headers },
    );
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
