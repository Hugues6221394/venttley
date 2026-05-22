"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createBrowserSupabase, syntheticEmail } from "@/lib/supabase/client";

export default function LoginForm() {
  const router = useRouter();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const supabase = createBrowserSupabase();
      const { data, error } = await supabase.auth.signInWithPassword({
        email: syntheticEmail(username),
        password,
      });
      if (error || !data.user) {
        throw new Error(error?.message ?? "Login failed");
      }
      // Role check happens server-side in the dashboard layout. We just
      // bounce there and let it gate access.
      router.replace("/overview");
      router.refresh();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Login failed";
      setError(msg);
      setBusy(false);
    }
  }

  return (
    <form className="flex flex-col gap-3" onSubmit={onSubmit}>
      <label className="text-xs font-semibold text-burgundy/80">
        Username
        <input
          className="mt-1 w-full rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm focus:border-berry"
          type="text"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          autoComplete="username"
          required
        />
      </label>
      <label className="text-xs font-semibold text-burgundy/80">
        Password
        <input
          className="mt-1 w-full rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm focus:border-berry"
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoComplete="current-password"
          required
        />
      </label>
      {error && (
        <p className="text-xs text-danger font-semibold">{error}</p>
      )}
      <button type="submit" className="btn-primary mt-2" disabled={busy}>
        {busy ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
