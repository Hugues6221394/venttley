import type { LucideIcon } from "lucide-react";
import {
  BarChart3, Compass, FileCheck2, Headset, Home, Inbox, KeyRound, LayoutDashboard, ListChecks, Scale,
  Server, ShieldAlert, ShieldCheck, SlidersHorizontal, Users, UsersRound,
} from "lucide-react";

// Presentation only: navigation groups and their membership live in lib/navigation.
const icons: Record<string, LucideIcon> = {
  "Daily work": LayoutDashboard,
  "Safety": ShieldAlert,
  "Moderation setup": SlidersHorizontal,
  "Community": UsersRound,
  "Insights": BarChart3,
  "Platform": Server,
  "Staff & access": KeyRound,
  "Compliance": FileCheck2,
};

const pageIcons: Record<string, LucideIcon> = {
  "/overview": Home,
  "/queue": ListChecks,
  "/inbox": Inbox,
  "/users": Users,
  "/moderation": ShieldCheck,
  "/appeals": Scale,
  "/support/cases": Headset,
};

export function groupIcon(label: string | undefined): LucideIcon {
  return (label && icons[label]) || Compass;
}

export function pageIcon(href: string): LucideIcon {
  return pageIcons[href] ?? Compass;
}
