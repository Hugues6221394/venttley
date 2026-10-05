"use client";

import Link, { useLinkStatus } from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import type { LucideIcon } from "lucide-react";
import { canAccess } from "@/lib/roles";
import { useStaffAttention } from "./staff-attention";
import { attentionDestination } from "@/lib/inbox-model";
import { BrandMark } from "./brand-mark";
import {
  LayoutDashboard,
  ShieldAlert,
  ShieldCheck,
  AlertTriangle,
  ImageIcon,
  Users,
  Users2,
  LineChart,
  TrendingUp,
  Megaphone,
  ScrollText,
  Activity,
  Flag,
  KeyRound,
  SettingsIcon,
  LifeBuoy,
  Sparkles,
  Scale,
  Music2,
  BriefcaseBusiness,
  Siren,
  BookOpenCheck,
  UserRoundCog,
  Database,
  UserSearch,
  ClipboardCheck,
  FileLock2,
  Eye,
  RefreshCw,
  Globe2,
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
      { href: "/inbox", label: "Staff inbox", icon: LifeBuoy },
      { href: "/queue-control", label: "Queue control", icon: ClipboardCheck },
      { href: "/safety",     label: "Safety & Crisis", icon: LifeBuoy },
      { href: "/csam",       label: "CSAM incidents", icon: AlertTriangle },
      { href: "/youth-safety", label: "Youth safety", icon: ShieldCheck },
      { href: "/moderation", label: "Moderation",     icon: ShieldAlert },
      { href: "/moderation/campaigns", label: "Harm campaigns", icon: UserSearch },
      { href: "/integrity", label: "Platform integrity", icon: UserSearch },
      { href: "/feed-integrity", label: "Feed integrity", icon: LineChart },
      { href: "/tribe-governance", label: "Tribe governance", icon: Users2 },
      { href: "/moderation/policies", label: "Policy center", icon: BookOpenCheck },
      { href: "/moderation/abuse", label: "Abuse intelligence", icon: UserSearch },
      { href: "/moderation/quality", label: "Moderation quality", icon: ClipboardCheck },
      { href: "/appeals",    label: "Appeals",        icon: Scale },
      { href: "/automod",    label: "Automod rules",  icon: ShieldCheck },
      { href: "/content",    label: "Content explorer", icon: Database },
      { href: "/media",      label: "Media safety",   icon: ImageIcon },
      { href: "/music",      label: "Music catalog",  icon: Music2 },
      { href: "/broadcasts", label: "Broadcasts",     icon: Megaphone },
      { href: "/delivery", label: "Delivery operations", icon: Megaphone },
      { href: "/crisis/playbooks", label: "Crisis playbooks", icon: Siren },
      { href: "/support/cases", label: "Support cases", icon: LifeBuoy },
    ],
  },
  {
    label: "Manage",
    items: [
      { href: "/users",  label: "Users",  icon: Users },
      { href: "/tribes", label: "Tribes", icon: Users2 },
      { href: "/roles",  label: "Roles & permissions", icon: KeyRound },
      { href: "/staff",  label: "Staff accounts", icon: UserRoundCog },
      { href: "/staff/invitations", label: "Staff invitations", icon: KeyRound },
      { href: "/staff/access-reviews", label: "Staff access reviews", icon: ClipboardCheck },
      { href: "/sessions", label: "Sessions & IPs", icon: Activity },
      { href: "/verification", label: "Verification queue", icon: Sparkles },
      { href: "/privacy", label: "Privacy requests", icon: FileLock2 },
      { href: "/evidence-access", label: "Evidence access", icon: Eye },
      { href: "/data-governance", label: "Data governance", icon: Database },
      { href: "/legal-requests", label: "Legal requests", icon: Scale },
      { href: "/recovery-readiness", label: "Recovery readiness", icon: RefreshCw },
      { href: "/moderation/workforce", label: "Moderation workforce", icon: Users2 },
      { href: "/regional-compliance", label: "Regional compliance", icon: Globe2 },
    ],
  },
  {
    label: "Insight",
    items: [
      { href: "/analytics", label: "Analytics", icon: LineChart },
      { href: "/impact", label: "Impact Center", icon: LifeBuoy },
      { href: "/slo",       label: "Service levels", icon: LineChart },
      { href: "/ops",       label: "Ops & cost", icon: TrendingUp },
      { href: "/audit",     label: "Audit log", icon: ScrollText },
      { href: "/system",    label: "System health", icon: Activity },
      { href: "/jobs",      label: "Jobs & delivery", icon: BriefcaseBusiness },
      { href: "/incidents", label: "Incident command", icon: Siren },
      { href: "/releases", label: "Release readiness", icon: RefreshCw },
      { href: "/model-operations", label: "Model operations", icon: Sparkles },
      { href: "/messaging-operations", label: "Messaging operations", icon: Megaphone },
      { href: "/storage-operations", label: "Storage operations", icon: Database },
      { href: "/transparency-reports", label: "Transparency reports", icon: ScrollText },
    ],
  },
  {
    label: "Control",
    items: [
      { href: "/flags",    label: "Feature flags", icon: Flag },
      { href: "/experiments", label: "Experiments", icon: LineChart },
      { href: "/approvals", label: "Sensitive approvals", icon: Scale },
      { href: "/policy/versions", label: "Policy versions", icon: BookOpenCheck },
      { href: "/emergency-access", label: "Emergency access", icon: Siren },
      { href: "/settings", label: "Settings",      icon: SettingsIcon },
    ],
  },
];

export default function Sidebar({
  role,
  badges,
}: {
  role?: string;
  badges?: Partial<Record<string, ReactNode>>;
}) {
  const pathname = usePathname();
  const { data: attention } = useStaffAttention();
  // Least-privilege: a role only sees the sections it may open. The middleware
  // is the hard gate; this just keeps the nav honest.
  const visibleGroups = groups
    .map((g) => ({
      ...g,
      items: g.items.filter((it) => canAccess(role, it.href)),
    }))
    .filter((g) => g.items.length > 0);
  const activeHref = visibleGroups
    .flatMap((group) => group.items)
    .filter((item) =>
      item.href === "/overview"
        ? pathname === "/" || pathname.startsWith("/overview")
        : pathname === item.href || pathname.startsWith(`${item.href}/`),
    )
    .sort((a, b) => b.href.length - a.href.length)[0]?.href;
  const isActive = (href: string) => href === activeHref;

  return (
    <aside className="w-64 shrink-0 hidden md:flex flex-col bg-white border-r border-line">
      <Link
        href="/overview"
        className="flex items-center gap-3 px-5 h-16 border-b border-line"
      >
        <BrandMark size={36} />
        <div className="leading-tight">
          <p className="text-[15px] font-semibold text-burgundy tracking-tight">Venttly</p>
          {/* The operator's own role, not a fixed wordmark. This read
              "Super Admin" for everyone, so a moderator's sidebar overstated
              their authority while the topbar correctly showed MODERATOR. On a
              console where knowing exactly what you may do is the point, the
              chrome should not disagree with itself. */}
          <p className="h-eyebrow">{(role ?? "staff").replace(/_/g, " ")}</p>
        </div>
      </Link>

      <nav className="flex-1 overflow-y-auto py-4 px-3 flex flex-col gap-5">
        {visibleGroups.map((g) => (
          <div key={g.label}>
            <p className="h-eyebrow px-3 mb-1.5">{g.label}</p>
            <div className="flex flex-col gap-0.5">
              {g.items.map((it) => {
                const active = isActive(it.href);
                const Icon = it.icon;
                return (
                  <Link
                    key={it.href}
                    href={attentionDestination(it.href, attention, false)}
                    prefetch={false}
                    aria-current={active ? "page" : undefined}
                    className={`nav-item relative ${active ? "nav-item-active" : ""}`}
                  >
                    <span className="flex items-center gap-2.5">
                      <Icon size={16} className={active ? "text-berry" : ""} />
                      <span>{it.label}</span>
                    </span>
                    {badges?.[it.href]}
                    <NavigationPending />
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

function NavigationPending() {
  const { pending } = useLinkStatus();
  return <span role="status" className={`pointer-events-none absolute inset-x-3 bottom-0 h-0.5 rounded-full bg-berry ${pending ? "opacity-100" : "opacity-0"}`}>
    <span className="sr-only">{pending ? "Opening workspace…" : ""}</span>
  </span>;
}
