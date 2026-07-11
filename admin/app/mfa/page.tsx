"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createBrowserSupabase } from "@/lib/supabase/client";

type Mode = "loading" | "enroll" | "challenge" | "done";

export default function MfaPage() {
  const router = useRouter();
  const [supabase] = useState(() => createBrowserSupabase());
  const [mode, setMode] = useState<Mode>("loading");
  const [factorId, setFactorId] = useState<string | null>(null);
  const [qrSvg, setQrSvg] = useState<string | null>(null);
  const [secret, setSecret] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Decide enroll vs challenge on load.
  useEffect(() => {
    (async () => {
      const { data: factors } = await supabase.auth.mfa.listFactors();
      const verified = factors?.totp?.find((f) => f.status === "verified");
      if (verified) {
        setFactorId(verified.id);
        setMode("challenge");
        return;
      }
      // No verified factor → enroll a fresh TOTP secret.
      const { data, error } = await supabase.auth.mfa.enroll({
        factorType: "totp",
        friendlyName: `console-${Date.now()}`,
      });
      if (error || !data) {
        setError(error?.message ?? "Could not start MFA enrolment.");
        setMode("enroll");
        return;
      }
      setFactorId(data.id);
      setQrSvg(data.totp.qr_code);
      setSecret(data.totp.secret);
      setMode("enroll");
    })();
  }, [supabase]);

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    if (!factorId) return;
    setBusy(true);
    setError(null);
    try {
      const { data: challenge, error: cErr } = await supabase.auth.mfa.challenge({
        factorId,
      });
      if (cErr || !challenge) throw new Error(cErr?.message ?? "Challenge failed");
      const { error: vErr } = await supabase.auth.mfa.verify({
        factorId,
        challengeId: challenge.id,
        code: code.trim(),
      });
      if (vErr) throw new Error(vErr.message);
      setMode("done");
      router.replace("/overview");
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Verification failed");
      setBusy(false);
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen flex items-center justify-center bg-canvas px-6">
      <div className="surface max-w-md w-full p-8">
        <div className="flex items-center gap-3 mb-4">
          <div className="h-9 w-9 rounded-xl bg-berry text-white flex items-center justify-center">
            🔐
          </div>
          <div>
            <h1 className="text-lg font-extrabold text-burgundy">
              Two-factor authentication
            </h1>
            <p className="h-eyebrow">Super Admin security</p>
          </div>
        </div>

        {mode === "loading" && (
          <p className="text-sm text-ink-muted">Checking your security setup…</p>
        )}

        {mode === "enroll" && (
          <>
            <p className="text-sm text-ink-muted mb-3">
              Scan this with an authenticator app (Google Authenticator, 1Password,
              Authy), then enter the 6-digit code to finish.
            </p>
            {qrSvg && (
              <div
                className="bg-white rounded-xl p-3 border border-line w-fit mx-auto mb-3"
                // Supabase returns the QR as an inline SVG data URI / markup.
                dangerouslySetInnerHTML={{ __html: qrSvg }}
              />
            )}
            {secret && (
              <p className="text-[11px] text-ink-muted text-center mb-4">
                Or enter this key manually:{" "}
                <code className="font-mono text-burgundy break-all">{secret}</code>
              </p>
            )}
          </>
        )}

        {mode === "challenge" && (
          <p className="text-sm text-ink-muted mb-3">
            Enter the current 6-digit code from your authenticator app to continue.
          </p>
        )}

        {(mode === "enroll" || mode === "challenge") && (
          <form className="flex flex-col gap-3" onSubmit={verify}>
            <input
              className="w-full text-center tracking-[0.4em] text-lg rounded-xl border border-mauve/50 bg-white px-3 py-2 font-mono focus:border-berry"
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={6}
              placeholder="000000"
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              required
            />
            {error && <p className="text-xs text-danger font-semibold">{error}</p>}
            <button
              className="btn-primary"
              type="submit"
              disabled={busy || code.length !== 6}
            >
              {busy ? "Verifying…" : mode === "enroll" ? "Activate 2FA" : "Verify"}
            </button>
          </form>
        )}

        <button
          onClick={signOut}
          className="text-xs text-ink-muted hover:underline mt-5 block mx-auto"
        >
          Sign out
        </button>
      </div>
    </main>
  );
}
