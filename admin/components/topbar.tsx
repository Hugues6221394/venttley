"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { canAccess } from "@/lib/roles";
import { Search, Bell, ChevronDown, LogOut, Globe2 } from "./ui/icons";
import { NotificationBell } from "./staff-inbox";
import { ThemePreferenceControl } from "./theme-preference";

export default function Topbar({
  pseudonym,
  role,
  env = "production",
  navigationControl,
}: {
  pseudonym: string;
  role: string;
  env?: "production" | "staging" | "local";
  navigationControl?: ReactNode;
}) {
  const [menu, setMenu] = useState(false);
  const menuRoot = useRef<HTMLDivElement>(null);
  const menuButton = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!menu) return;
    const onPointer = (event: PointerEvent) => {
      if (!menuRoot.current?.contains(event.target as Node)) setMenu(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { setMenu(false); menuButton.current?.focus(); }
    };
    document.addEventListener("pointerdown", onPointer);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("pointerdown", onPointer); document.removeEventListener("keydown", onKey); };
  }, [menu]);
  // Keep what was searched in the box after navigating, so refining a query
  // does not mean retyping it.
  const query = useSearchParams().get("q") ?? "";
  const envTone =
    env === "production"
      ? "bg-ok/12 text-ok"
      : env === "staging"
        ? "bg-warn/15 text-warn"
        : "bg-info/12 text-info";

  return (
    <header className="h-16 shrink-0 bg-white border-b border-line flex items-center px-6 gap-4">
      {navigationControl}
      {/* A submit, not a live query. Every search is audited — searching for
          a member on a pseudonymous platform is exactly the act that should be
          reviewable — and querying per keystroke would flood that ledger and
          let the box enumerate the platform a letter at a time. */}
      {canAccess(role, "/search") && <form action="/search" method="get" className="flex-1 max-w-xl relative">
        <Search
          size={16}
          className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted"
        />
        <input
          name="q"
          aria-label="Search members and content (audited)"
          defaultValue={query}
          minLength={4}
          required
          className="input pl-9"
          placeholder="Search users, posts, tribes, or paste any ID…"
          onKeyDown={(e) => {
            if (e.key === "Escape") (e.currentTarget as HTMLInputElement).blur();
          }}
        />
      </form>}

      <div className="flex items-center gap-2 ml-auto">
        <span
          className={`pill ${envTone}`}
          title="Environment of the data on this dashboard"
        >
          <Globe2 size={11} />
          {env}
        </span>

        <NotificationBell />

        <div ref={menuRoot} className="relative" onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setMenu(false);
        }}>
          <button
            type="button"
            ref={menuButton}
            aria-label="Account menu"
            aria-expanded={menu}
            aria-controls="staff-account-menu"
            className="flex items-center gap-2 rounded-lg border border-line bg-white pl-2 pr-2.5 h-9 hover:bg-canvas"
            onClick={() => setMenu((m) => !m)}
          >
            <div className="h-6 w-6 rounded-md bg-berry text-white text-[11px] font-extrabold flex items-center justify-center">
              {pseudonym.slice(0, 2).toUpperCase()}
            </div>
            <div className="text-left leading-tight hidden sm:block">
              <p className="text-xs font-extrabold text-burgundy">
                @{pseudonym}
              </p>
              <p className="text-[10px] text-ink-muted uppercase tracking-wider">
                {role}
              </p>
            </div>
            <ChevronDown size={14} className="text-ink-muted" />
          </button>
          {menu && (
            <div id="staff-account-menu" className="absolute right-0 top-11 surface w-56 p-1 z-30">
              <p className="px-3 pt-2 pb-1 h-eyebrow">Signed in</p>
              <p className="px-3 pb-2 text-sm font-bold text-burgundy">
                @{pseudonym}
              </p>
              <div className="border-t border-line my-1" />
              <ThemePreferenceControl />
              {canAccess(role, "/settings") && <Link href="/settings" prefetch={false} className="nav-item" onClick={() => setMenu(false)}>Settings</Link>}
              {canAccess(role, "/audit") && <Link href="/audit" prefetch={false} className="nav-item" onClick={() => setMenu(false)}>Recent audit entries</Link>}
              <form action="/api/auth/logout" method="post">
                <button type="submit" className="nav-item w-full text-left">
                  <LogOut size={14} />
                  Sign out
                </button>
              </form>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
