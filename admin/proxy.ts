import { NextResponse, type NextRequest } from "next/server";
import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { ipAllowed } from "@/lib/ip-allowlist";
import { canAccess, isStaffRole, landingFor } from "@/lib/roles";

type CookieToSet = { name: string; value: string; options?: CookieOptions };

// The server-side proxy is the console's front door. Three layers, in order:
//   1. IP allowlist   — network-level gate (ADMIN_IP_ALLOWLIST), applies to
//                       every route incl. /login so attackers can't even reach
//                       the form from a disallowed network.
//   2. MFA (AAL2)     — a signed-in admin with a verified TOTP factor must
//                       complete the step-up challenge before touching the app.
//   3. Least-privilege — role → section authorization (lib/roles.ts). Deep
//                       links a role can't use bounce to their landing page.
// It also refreshes the Supabase session cookie on every request.

/**
 * The caller's real IP.
 *
 * CF-Connecting-IP first, and it is the only one of these an attacker cannot
 * set: Cloudflare overwrites it on every proxied request, whereas
 * X-Forwarded-For is client-supplied and merely appended to. Reading XFF's
 * first entry — which this did — means anyone can name their own IP and walk
 * straight through ADMIN_IP_ALLOWLIST.
 *
 * That only holds while requests actually arrive through Cloudflare, which is
 * what the origin check below enforces. The two go together: trusting
 * CF-Connecting-IP without locking the origin just moves the forgery one
 * header along.
 */
function clientIp(req: NextRequest): string | null {
  return (
    req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    null
  );
}

/**
 * Requests must arrive through Cloudflare, not straight at the origin.
 *
 * A Vercel deployment answers on its own *.vercel.app hostname as well as the
 * custom domain. Anything in front of admin.venttly.com — Cloudflare Access,
 * the WAF, the IP allowlist, CF-Connecting-IP itself — is simply absent on
 * that hostname. Without this check, finding the origin URL bypasses every
 * edge control at once, and origin URLs are not secret: they appear in
 * certificate transparency logs.
 *
 * Cloudflare sets the header with a Transform Rule; ADMIN_ORIGIN_SECRET holds
 * the same value here. Unset means unenforced, so local development and a
 * first deploy before the rule exists still work — the deployment checklist
 * covers turning it on, and /system reports whether it is.
 */
function fromCloudflare(req: NextRequest): boolean {
  const expected = process.env.ADMIN_ORIGIN_SECRET?.trim();
  if (!expected) return true;
  const presented = req.headers.get("x-venttly-origin");
  if (!presented || presented.length !== expected.length) return false;
  // Constant-time-ish: compare every byte regardless of where they differ, so
  // response timing does not leak a prefix of the secret.
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ presented.charCodeAt(i);
  }
  return diff === 0;
}

export async function proxy(req: NextRequest) {
  const { pathname } = req.nextUrl;

  // 0) Reached through the front door, not around it.
  if (!fromCloudflare(req)) {
    return new NextResponse("Not found", { status: 404 });
  }

  // 1) IP allowlist.
  if (!ipAllowed(clientIp(req))) {
    return new NextResponse("Forbidden — this network is not permitted.", {
      status: 403,
    });
  }

  // Refresh session cookies (standard @supabase/ssr middleware pattern).
  let res = NextResponse.next({ request: req });
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return req.cookies.getAll();
        },
        setAll(cookiesToSet: CookieToSet[]) {
          cookiesToSet.forEach(({ name, value }) => req.cookies.set(name, value));
          res = NextResponse.next({ request: req });
          cookiesToSet.forEach(({ name, value, options }) =>
            res.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Public paths: no auth required.
  if (pathname === "/login" || pathname.startsWith("/api/auth")) {
    return res;
  }

  if (!user) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    return NextResponse.redirect(url);
  }

  // The MFA area is reachable by any signed-in user (to enroll / challenge).
  // Skip the MFA + role gates here to avoid a redirect loop.
  if (pathname.startsWith("/mfa")) return res;

  // 2) MFA step-up.
  const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (aal) {
    const requireMfa = process.env.ADMIN_REQUIRE_MFA === "true";
    const needsChallenge =
      aal.nextLevel === "aal2" && aal.currentLevel !== "aal2";
    const needsEnroll = requireMfa && aal.nextLevel === "aal1";
    if (needsChallenge || needsEnroll) {
      const url = req.nextUrl.clone();
      url.pathname = "/mfa";
      return NextResponse.redirect(url);
    }
  }

  // 3) Role-based least-privilege — an optimistic pre-filter, not the gate.
  //
  // Deliberately still role-only. This runs on every request including
  // prefetches, and Next's own guidance is that the proxy must not carry
  // authorization or do database work for that reason
  // (01-getting-started/16-proxy.md, and 02-guides/authentication.md's
  // "Optimistic checks with Proxy"). A first pass added the standing check
  // here as well and doubled the round trips on every prefetched link to buy
  // nothing: a suspended moderator turned away here would be turned away by
  // the layout anyway, one navigation later, having read no data.
  //
  // The authoritative check — role *and* standing, asked of is_staff — lives
  // where the data is: app/(dashboard)/layout.tsx, which gates every
  // service-role read, and each app/api route. See lib/staff.ts.
  const { data: row } = await supabase
    .from("users")
    .select("user_role")
    .eq("user_id", user.id)
    .maybeSingle();
  const role = row?.user_role as string | undefined;

  if (!isStaffRole(role)) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    return NextResponse.redirect(url);
  }
  if (!canAccess(role, pathname)) {
    const url = req.nextUrl.clone();
    url.pathname = landingFor(role);
    return NextResponse.redirect(url);
  }

  return res;
}

export const config = {
  // Everything except Next internals and static assets.
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)",
  ],
};
