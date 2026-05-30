"use client";

import { useState } from "react";
import { Search, Bell, ChevronDown, LogOut, Globe2 } from "./ui/icons";

export default function Topbar({
  pseudonym,
  role,
  env = "production",
  unread = 0,
}: {
  pseudonym: string;
  role: string;
  env?: "production" | "staging" | "local";
  unread?: number;
}) {
  const [menu, setMenu] = useState(false);
  const envTone =
    env === "production"
      ? "bg-ok/12 text-ok"
      : env === "staging"
        ? "bg-warn/15 text-warn"
        : "bg-info/12 text-info";

  return (
    <header className="h-16 shrink-0 bg-white border-b border-line flex items-center px-6 gap-4">
      <div className="flex-1 max-w-xl relative">
        <Search
          size={16}
          className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted"
        />
        <input
          className="input pl-9"
          placeholder="Search users, posts, tribes, reports… (⌘K)"
          onKeyDown={(e) => {
            if (e.key === "Escape") (e.currentTarget as HTMLInputElement).blur();
          }}
        />
      </div>

      <div className="flex items-center gap-2 ml-auto">
        <span
          className={`pill ${envTone}`}
          title="Environment of the data on this dashboard"
        >
          <Globe2 size={11} />
          {env}
        </span>

        <button
          className="icon-btn relative"
          aria-label="Notifications"
          type="button"
        >
          <Bell size={16} />
          {unread > 0 && (
            <span className="absolute -top-1 -right-1 min-w-4 h-4 px-1 rounded-full bg-danger text-white text-[10px] font-bold leading-4 text-center">
              {unread > 99 ? "99+" : unread}
            </span>
          )}
        </button>

        <div className="relative">
          <button
            type="button"
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
            <div className="absolute right-0 top-11 surface w-56 p-1 z-30">
              <p className="px-3 pt-2 pb-1 h-eyebrow">Signed in</p>
              <p className="px-3 pb-2 text-sm font-bold text-burgundy">
                @{pseudonym}
              </p>
              <div className="border-t border-line my-1" />
              <a href="/settings" className="nav-item">Settings</a>
              <a href="/audit" className="nav-item">Recent audit entries</a>
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
