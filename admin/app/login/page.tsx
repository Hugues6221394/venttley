import Link from "next/link";
import LoginForm from "@/components/login-form";
import PasswordResetForm from "@/components/password-reset-form";

/**
 * Sign in, and recover.
 *
 * The reset flow lives here behind ?reset=1 rather than at its own path, and
 * that is deliberate: proxy.ts admits exactly two things without a session —
 * `pathname === "/login"` and anything under /api/auth. A separate
 * /forgot-password route would be redirected straight back to this page by the
 * front door, so the recovery path would exist and be unreachable. A query
 * string does not change the pathname, so this stays inside the one page the
 * proxy already trusts.
 */
export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ reset?: string }>;
}) {
  const { reset } = await searchParams;
  const resetting = reset === "1";
  const justReset = reset === "done";

  return (
    <main className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blush to-cardBlush px-6">
      <div className="card w-full max-w-sm p-8">
        <div className="flex flex-col items-center mb-6">
          <div className="h-14 w-14 rounded-2xl bg-berry flex items-center justify-center text-white text-2xl shadow-card">
            ♡
          </div>
          <h1 className="mt-4 text-xl font-extrabold text-burgundy">
            Venttly Admin
          </h1>
          <p className="text-xs text-burgundy/60 mt-1">
            {resetting ? "Reset your password." : "Super-admin access only."}
          </p>
        </div>

        {justReset && (
          <p className="mb-4 rounded-xl bg-ok/10 px-3 py-2 text-xs font-semibold text-ok">
            Password changed. Every other session was signed out — sign in again.
          </p>
        )}

        {resetting ? <PasswordResetForm /> : <LoginForm />}

        {!resetting && (
          <Link
            href="/login?reset=1"
            className="mt-4 block text-center text-xs text-burgundy/60 hover:underline"
          >
            Forgot your password?
          </Link>
        )}
      </div>
    </main>
  );
}
