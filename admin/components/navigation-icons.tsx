import type { LucideIcon } from "lucide-react";
import { LayoutDashboard, ShieldCheck, Users, Server, Landmark, BarChart3, Compass } from "lucide-react";

// Presentation only: navigation groups and their membership live in lib/navigation.
const icons: Record<string, LucideIcon> = {
  "Command Center": LayoutDashboard,
  "Trust & Safety": ShieldCheck,
  "Members & Communities": Users,
  "Platform Operations": Server,
  "Governance & Access": Landmark,
  "Insights & Impact": BarChart3,
};

export function groupIcon(label: string | undefined): LucideIcon {
  return (label && icons[label]) || Compass;
}
