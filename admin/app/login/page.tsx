import Link from "next/link";
import LoginForm from "@/components/login-form";
import PasswordResetForm from "@/components/password-reset-form";
import { BrandMark } from "@/components/brand-mark";

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
    <main className="min-h-screen flex items-center justify-center bg-canvas px-6">
      <div className="card w-full max-w-sm p-8 shadow-lift">
        <div className="flex flex-col items-center mb-7 text-center">
          <BrandMark size={56} />
          <h1 className="mt-4 text-[22px] font-semibold tracking-tight text-burgundy">
            Venttly
          </h1>
          <p className="text-[13px] text-ink-muted mt-1">
            {resetting ? "Reset your password." : "Operator console"}
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
