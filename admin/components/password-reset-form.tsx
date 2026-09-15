"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";

/**
 * Two steps: ask for a code, then use it.
 *
 * The first step's response is deliberately uninformative — the same words
 * whether or not the account exists, whether or not it has a verified recovery
 * address. This page is reachable without a session, so anything else would
 * turn it into a way to ask "does this person have an admin account here".
 * That is why the copy says "if that account has a verified recovery email"
 * rather than "sent": the second is a claim we have decided not to make.
 */
export default function PasswordResetForm() {
  const router = useRouter();
  const [step, setStep] = useState<"request" | "confirm">("request");
  const [username, setUsername] = useState("");
  const [code, setCode] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  async function post(body: Record<string, unknown>) {
    const res = await fetch("/api/auth/password-reset", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return { ok: res.ok, body: (await res.json()) as { ok?: boolean; error?: string } };
  }

  async function onRequest(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const { body } = await post({ action: "request", identifier: username.trim() });
      if (body.error) throw new Error(body.error);
      setNotice(
        "If that account has a verified recovery email, a code is on its way. " +
          "It expires in 15 minutes.",
      );
      setStep("confirm");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start the reset.");
    } finally {
      setBusy(false);
    }
  }

  async function onConfirm(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    // Checked here only to save a round trip and the one attempt it would
    // spend; the code is single-use and the server counts tries.
    if (password !== confirm) {
      setError("The two passwords do not match.");
      return;
    }
    setBusy(true);
    try {
      const { ok, body } = await post({
        action: "confirm",
        identifier: username.trim(),
        code: code.trim(),
        new_password: password,
      });
      if (!ok || body.error) throw new Error(body.error ?? "That code did not work.");
      // Every existing session is revoked server-side as part of the reset, so
      // there is nothing to carry over — sign in fresh.
      router.replace("/login?reset=done");
    } catch (err) {
      setError(err instanceof Error ? err.message : "That code did not work.");
    } finally {
      setBusy(false);
    }
  }

  const field =
    "mt-1 w-full rounded-xl border border-line px-3 py-2 text-sm text-burgundy " +
    "focus:outline-none focus:ring-2 focus:ring-berry/30";

  return (
    <form
      className="flex flex-col gap-3"
      onSubmit={step === "request" ? onRequest : onConfirm}
    >
      <label className="text-xs font-semibold text-burgundy/80">
        Username
        <input
          className={field}
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          autoComplete="username"
          disabled={step === "confirm"}
          required
        />
      </label>

      {step === "confirm" && (
        <>
          <label className="text-xs font-semibold text-burgundy/80">
            Code from your recovery email
            <input
              className={field}
              value={code}
              onChange={(e) => setCode(e.target.value)}
              inputMode="numeric"
              autoComplete="one-time-code"
              required
            />
          </label>
          <label className="text-xs font-semibold text-burgundy/80">
            New password
            <input
              className={field}
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="new-password"
              required
            />
          </label>
          <label className="text-xs font-semibold text-burgundy/80">
            Repeat new password
            <input
              className={field}
              type="password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              autoComplete="new-password"
              required
            />
          </label>
        </>
      )}

      {notice && <p className="text-xs text-burgundy/70">{notice}</p>}
      {error && <p className="text-xs font-semibold text-danger">{error}</p>}

      <button
        type="submit"
        disabled={busy}
        className="mt-1 rounded-xl bg-berry px-4 py-2 text-sm font-bold text-white disabled:opacity-60"
      >
        {busy
          ? "Working…"
          : step === "request"
            ? "Send me a code"
            : "Set new password"}
      </button>

      <Link href="/login" className="text-center text-xs text-burgundy/60 hover:underline">
        Back to sign in
      </Link>
    </form>
  );
}
