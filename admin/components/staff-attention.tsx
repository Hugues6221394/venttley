"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import { parseAttention, pollDelay, staleTimestamp, type StaffAttention } from "@/lib/inbox-model";

export class InboxAccessError extends Error {}
export async function inboxRequest(params: URLSearchParams, signal?: AbortSignal, body?: object) {
  const response = await fetch(`/inbox/data?${params}`, {
    method: body ? "POST" : "GET", credentials: "same-origin", cache: "no-store", redirect: "error", signal,
    ...(body ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {}),
  });
  if (response.status === 401 || response.status === 403) throw new InboxAccessError("Your staff access must be verified again.");
  if (!response.ok) throw new Error("Notifications could not be refreshed. Please retry.");
  return response.json();
}

type AttentionContext = {
  available: boolean; queuesAvailable: boolean; data: StaffAttention | null; error: string | null;
  loading: boolean; stale: boolean; revision: number; refresh: () => void;
};
const Context = createContext<AttentionContext>({ available: false, queuesAvailable: false, data: null, error: null, loading: false, stale: false, revision: 0, refresh: () => {} });
export const useStaffAttention = () => useContext(Context);

// Revalidated Server Component pages supply a fresh opaque render token so a
// repeated successful action at the same URL still refreshes shared attention.
export function RefreshAttentionOnRender({ token }: { token: string }) {
  const { refresh } = useStaffAttention();
  useEffect(() => { refresh(); }, [token, refresh]);
  return null;
}

export function StaffAttentionProvider({ available, queuesAvailable=false, children }: { available: boolean; queuesAvailable?: boolean; children: ReactNode }) {
  const [data, setData] = useState<StaffAttention | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [revision, setRevision] = useState(0);
  const [clock, setClock] = useState(Date.now());
  const reload = useRef<() => void>(() => {});
  const pathname = usePathname();
  const query = useSearchParams().toString();
  const lastLocation = useRef(`${pathname}?${query}`);
  const refresh = useCallback(() => reload.current(), []);
  useEffect(() => {
    if (!available && !queuesAvailable) { setData(null); setError(null); return; }
    let stopped = false, failures = 0, pending = false, rerun = false, lastStart = 0;
    let timer: ReturnType<typeof setTimeout>;
    let controller: AbortController | null = null;
    const schedule = () => { clearTimeout(timer); if (!stopped && !document.hidden) timer = setTimeout(run, pollDelay(failures)); };
    async function run() {
      if (stopped || document.hidden) return;
      if (pending) { rerun = true; return; }
      pending = true; lastStart = Date.now(); setLoading(true); controller = new AbortController();
      const timeout = setTimeout(() => controller?.abort(), 12_000);
      try {
        const result = parseAttention(await inboxRequest(new URLSearchParams({ mode: "attention" }), controller.signal));
        if (stopped) return;
        if (!result) throw new Error("Invalid response");
        setData(result); setError(null); failures = 0;
      } catch (cause) {
        if (stopped) return;
        // Clear prior counts on errors; never render an old privileged snapshot
        // as healthy, or retain it after a role/session change.
        setData(null); setError(cause instanceof InboxAccessError ? cause.message : "Attention counts unavailable. Retry when your connection or session is restored."); failures++;
      } finally {
        clearTimeout(timeout); pending = false;
        if (!stopped) { setLoading(false); setClock(Date.now()); setRevision(value => value + 1);
          if (rerun) { rerun = false; clearTimeout(timer); timer = setTimeout(run, 500); } else schedule(); }
      }
    }
    const focus = () => { if (!document.hidden && Date.now() - lastStart > 1000) void run(); };
    const visibility = () => { clearTimeout(timer); if (document.hidden) { rerun = false; controller?.abort(); } else focus(); };
    reload.current = () => { clearTimeout(timer); void run(); };
    window.addEventListener("focus", focus); window.addEventListener("online", focus);
    document.addEventListener("visibilitychange", visibility);
    const ageTick = setInterval(() => { if (!document.hidden) setClock(Date.now()); }, 15_000);
    void run();
    return () => { stopped = true; clearTimeout(timer); clearInterval(ageTick); controller?.abort(); reload.current = () => {};
      window.removeEventListener("focus", focus); window.removeEventListener("online", focus); document.removeEventListener("visibilitychange", visibility); };
  }, [available, queuesAvailable]);
  useEffect(() => {
    const location = `${pathname}?${query}`;
    if (lastLocation.current !== location) { lastLocation.current = location; refresh(); }
  }, [pathname, query, refresh]);
  const stale = !!data?.enabled && (staleTimestamp(data.generated_at, clock) || staleTimestamp(data.worker_at, clock));
  return <Context.Provider value={{ available, queuesAvailable, data, error, loading, stale, revision, refresh }}>{children}</Context.Provider>;
}
