"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { LucideIcon } from "lucide-react";
import {
  LayoutDashboard,
  ShieldAlert,
  Users,
  Users2,
  LineChart,
  Megaphone,
  ScrollText,
  Activity,
  Flag,
  KeyRound,
  SettingsIcon,
  Heart,
  Sparkles,
} from "./ui/icons";

type Item = {
  href: string;
  label: string;
  icon: LucideIcon;
  badge?: number;
};

type Group = {
  label: string;
  items: Item[];
};

const groups: Group[] = [
  {
    label: "Operate",
    items: [
      { href: "/overview",   label: "Control Center", icon: LayoutDashboard },
      { href: "/moderation", label: "Moderation",     icon: ShieldAlert },
      { href: "/broadcasts", label: "Broadcasts",     icon: Megaphone },
    ],
  },
  {
    label: "Manage",
    items: [
      { href: "/users",  label: "Users",  icon: Users },
      { href: "/tribes", label: "Tribes", icon: Users2 },
      { href: "/roles",  label: "Roles & permissions", icon: KeyRound },
    ],
  },
  {
    label: "Insight",
    items: [
      { href: "/analytics", label: "Analytics", icon: LineChart },
      { href: "/audit",     label: "Audit log", icon: ScrollText },
      { href: "/system",    label: "System health", icon: Activity },
    ],
  },
  {
    label: "Control",
    items: [
      { href: "/flags",    label: "Feature flags", icon: Flag },
      { href: "/settings", label: "Settings",      icon: SettingsIcon },
    ],
  },
];

export default function Sidebar({
  pendingReports = 0,
  openIncidents = 0,
}: {
  pendingReports?: number;
  openIncidents?: number;
}) {
  const pathname = usePathname();
  const isActive = (href: string) =>
    href === "/overview"
      ? pathname === "/" || pathname.startsWith("/overview")
      : pathname.startsWith(href);

  return (
    <aside className="w-64 shrink-0 hidden md:flex flex-col bg-white border-r border-line">
      <Link
        href="/overview"
        className="flex items-center gap-3 px-5 h-16 border-b border-line"
      >
        <div className="h-9 w-9 rounded-xl bg-berry text-white flex items-center justify-center shadow-soft">
          <Heart size={18} fill="currentColor" />
        </div>
        <div className="leading-tight">
          <p className="text-[15px] font-extrabold text-burgundy">Venttly</p>
          <p className="h-eyebrow">Super Admin</p>
        </div>
      </Link>

      <nav className="flex-1 overflow-y-auto py-4 px-3 flex flex-col gap-5">
        {groups.map((g) => (
          <div key={g.label}>
            <p className="h-eyebrow px-3 mb-1.5">{g.label}</p>
            <div className="flex flex-col gap-0.5">
              {g.items.map((it) => {
                const active = isActive(it.href);
                const Icon = it.icon;
                const badge =
                  it.href === "/moderation"
                    ? pendingReports
                    : it.href === "/system"
                      ? openIncidents
                      : undefined;
                return (
                  <Link
                    key={it.href}
                    href={it.href}
                    className={`nav-item ${active ? "nav-item-active" : ""}`}
                  >
                    <span className="flex items-center gap-2.5">
                      <Icon size={16} className={active ? "text-berry" : ""} />
                      <span>{it.label}</span>
                    </span>
                    {badge !== undefined && badge > 0 && (
                      <span className="pill bg-danger/15 text-danger">
                        {badge}
                      </span>
                    )}
                  </Link>
                );
              })}
            </div>
          </div>
        ))}
      </nav>

      <div className="p-4 border-t border-line">
        <div className="surface-flat p-3 flex items-start gap-2">
          <Sparkles size={14} className="text-berry mt-0.5" />
          <div>
            <p className="text-xs font-bold text-burgundy">v0.2 console</p>
            <p className="text-[11px] text-ink-muted leading-tight">
              Every privileged action is audit-logged.
            </p>
          </div>
        </div>
      </div>
    </aside>
  );
}
