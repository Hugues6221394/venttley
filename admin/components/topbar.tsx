"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { canAccess } from "@/lib/roles";
import { Search, ChevronDown, LogOut, SettingsIcon, ScrollText } from "./ui/icons";
import { NotificationBell } from "./staff-inbox";
import { ThemePreferenceControl } from "./theme-preference";

export default function Topbar({
  pseudonym,
  role,
  env = "production",
  navigationControl,
  commandControl,
}: {
  pseudonym: string;
  role: string;
  env?: "production" | "staging" | "local";
  navigationControl?: ReactNode;
  commandControl?: ReactNode;
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
  const initials = pseudonym.slice(0, 2).toUpperCase();
  const roleLabel = role.replaceAll("_", " ");

  return (
    <header className="console-topbar">
      {navigationControl}
      {/* A submit, not a live query. Every search is audited — searching for
          a member on a pseudonymous platform is exactly the act that should be
          reviewable — and querying per keystroke would flood that ledger and
          let the box enumerate the platform a letter at a time. */}
      {canAccess(role, "/search") && <form action="/search" method="get" className="console-search">
        <Search size={15} aria-hidden="true" />
        <input
          name="q"
          aria-label="Search members and content (audited)"
          defaultValue={query}
          minLength={4}
          required
          className="console-search-input"
          placeholder="Search members, posts, tribes or IDs…"
          onKeyDown={(e) => {
            if (e.key === "Escape") (e.currentTarget as HTMLInputElement).blur();
          }}
        />
        <span className="console-search-hint" aria-hidden="true">Audited · ↵</span>
      </form>}

      <div className="console-topbar-actions">
        {commandControl}
        <span className={`console-env console-env-${env}`} title={`Environment of the data on this dashboard: ${env}`}>
          <span className="console-env-label">{env}</span>
        </span>
        <NotificationBell />
        <span className="console-divider" aria-hidden="true" />

        <div ref={menuRoot} className="relative" onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setMenu(false);
        }}>
          <button
            type="button"
            ref={menuButton}
            aria-label="Account menu"
            aria-expanded={menu}
            aria-controls="staff-account-menu"
            className="console-account"
            onClick={() => setMenu((m) => !m)}
          >
            <span className="console-avatar" aria-hidden="true">{initials}</span>
            <span className="console-account-text text-left hidden sm:block">
              <p className="console-account-name">@{pseudonym}</p>
              <p className="console-account-role">{roleLabel}</p>
            </span>
            <ChevronDown size={14} className="text-ink-muted" aria-hidden="true" />
          </button>
          {menu && (
            <div id="staff-account-menu" className="console-menu">
              <div className="console-menu-head">
                <span className="console-avatar" aria-hidden="true">{initials}</span>
                <div className="min-w-0">
                  <p className="h-eyebrow">Signed in</p>
                  <p className="truncate text-sm font-semibold text-burgundy">@{pseudonym}</p>
                </div>
              </div>
              <ThemePreferenceControl />
              <div className="p-1">
                {canAccess(role, "/settings") && <Link href="/settings" prefetch={false} className="nav-item justify-start" onClick={() => setMenu(false)}><SettingsIcon size={14} aria-hidden="true" />Settings</Link>}
                {canAccess(role, "/audit") && <Link href="/audit" prefetch={false} className="nav-item justify-start" onClick={() => setMenu(false)}><ScrollText size={14} aria-hidden="true" />Recent audit entries</Link>}
                <form action="/api/auth/logout" method="post">
                  <button type="submit" className="nav-item justify-start w-full text-left">
                    <LogOut size={14} aria-hidden="true" />
                    Sign out
                  </button>
                </form>
              </div>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
