"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

type Item = {
  href: string;
  label: string;
  icon: string;
  ready?: boolean;
};

const items: Item[] = [
  { href: "/overview",      label: "Overview",      icon: "▦", ready: true },
  { href: "/moderation",    label: "Moderation",    icon: "▲", ready: true },
  { href: "/users",         label: "Users",         icon: "◉", ready: true },
  { href: "/tribes",        label: "Tribes",        icon: "◍" },
  { href: "/analytics",     label: "Analytics",     icon: "◮" },
  { href: "/notifications", label: "Notifications", icon: "✦" },
  { href: "/settings",      label: "Settings",      icon: "❖" },
];

export default function Sidebar() {
  const pathname = usePathname();
  return (
    <aside className="w-60 shrink-0 hidden md:flex flex-col bg-white border-r border-mauve/30 px-4 py-6">
      <Link href="/overview" className="flex items-center gap-2 mb-8">
        <div className="h-9 w-9 rounded-xl bg-berry text-white flex items-center justify-center text-lg shadow-card">
          ♡
        </div>
        <div>
          <p className="text-sm font-extrabold leading-none text-burgundy">
            Venttly
          </p>
          <p className="text-[10px] uppercase tracking-widest text-burgundy/60">
            Admin
          </p>
        </div>
      </Link>
      <nav className="flex flex-col gap-1">
        {items.map((it) => {
          const active = pathname.startsWith(it.href);
          return (
            <Link
              key={it.href}
              href={it.href}
              className={`flex items-center justify-between gap-2 rounded-xl px-3 py-2 text-sm font-semibold transition ${
                active
                  ? "bg-berry/12 text-berry"
                  : "text-burgundy/75 hover:bg-cardBlush"
              }`}
            >
              <span className="flex items-center gap-2">
                <span className="text-base leading-none">{it.icon}</span>
                <span>{it.label}</span>
              </span>
              {!it.ready && (
                <span className="pill bg-mauve/25 text-burgundy/70">soon</span>
              )}
            </Link>
          );
        })}
      </nav>
      <p className="mt-auto text-[10px] text-burgundy/40">
        v0.1 · Admin console
      </p>
    </aside>
  );
}
