import { NextResponse, type NextRequest } from "next/server";
import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { ipAllowed } from "@/lib/ip-allowlist";
import { canAccess, isStaffRole, landingFor } from "@/lib/roles";

type CookieToSet = { name: string; value: string; options?: CookieOptions };

// Edge middleware = the console's front door. Three layers, in order:
//   1. IP allowlist   — network-level gate (ADMIN_IP_ALLOWLIST), applies to
//                       every route incl. /login so attackers can't even reach
//                       the form from a disallowed network.
//   2. MFA (AAL2)     — a signed-in admin with a verified TOTP factor must
//                       complete the step-up challenge before touching the app.
//   3. Least-privilege — role → section authorization (lib/roles.ts). Deep
//                       links a role can't use bounce to their landing page.
// It also refreshes the Supabase session cookie on every request.

function clientIp(req: NextRequest): string | null {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    null
  );
}

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;

  // 1) IP allowlist — before anything else.
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

  // 3) Role-based least-privilege.
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
