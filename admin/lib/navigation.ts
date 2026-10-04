import { canAccess } from "./roles";

// Static page metadata only. Never include member identifiers, query strings,
// case content, or database search results in navigation or browser preferences.
export const navigationGroups = [
  { label: "Command Center", pages: [
    ["/overview", "Control Center"], ["/inbox", "Staff inbox"], ["/queue-control", "Queue control"],
    ["/incidents", "Incident command"],
  ] },
  { label: "Trust & Safety", pages: [
    ["/safety", "Safety & Crisis"], ["/csam", "CSAM incidents"],
    ["/youth-safety", "Youth safety"], ["/moderation", "Moderation"],
    ["/moderation/campaigns", "Harm campaigns"], ["/integrity", "Platform integrity"],
    ["/feed-integrity", "Feed integrity"], ["/moderation/policies", "Policy center"],
    ["/moderation/abuse", "Abuse intelligence"], ["/moderation/quality", "Moderation quality"],
    ["/appeals", "Appeals"], ["/automod", "Automod rules"],
    ["/media", "Media safety"], ["/crisis/playbooks", "Crisis playbooks"],
    ["/moderation/workforce", "Moderation workforce"],
  ] },
  { label: "Members & Communities", pages: [
    ["/users", "Users"], ["/tribes", "Tribes"], ["/tribe-governance", "Tribe governance"],
    ["/content", "Content explorer"], ["/music", "Music catalog"],
    ["/verification", "Verification queue"], ["/support/cases", "Support cases"],
    ["/feedback", "Bugs & suggestions"],
  ] },
  { label: "Platform Operations", pages: [
    ["/system", "System health"], ["/slo", "Service levels"], ["/ops", "Ops & cost"],
    ["/jobs", "Jobs & delivery"], ["/delivery", "Delivery operations"],
    ["/model-operations", "Model operations"], ["/messaging-operations", "Messaging operations"],
    ["/storage-operations", "Storage operations"], ["/releases", "Release readiness"],
    ["/recovery-readiness", "Recovery readiness"], ["/flags", "Feature flags"],
    ["/experiments", "Experiments"], ["/broadcasts", "Broadcasts"],
  ] },
  { label: "Governance & Access", pages: [
    ["/roles", "Roles & permissions"], ["/staff", "Staff accounts"],
    ["/staff/invitations", "Staff invitations"], ["/staff/access-reviews", "Staff access reviews"],
    ["/sessions", "Sessions & IPs"], ["/privacy", "Privacy requests"],
    ["/evidence-access", "Evidence access"], ["/data-governance", "Data governance"],
    ["/legal-requests", "Legal requests"], ["/regional-compliance", "Regional compliance"],
    ["/approvals", "Sensitive approvals"], ["/policy/versions", "Policy versions"],
    ["/emergency-access", "Emergency access"], ["/settings", "Settings"], ["/audit", "Audit log"],
  ] },
  { label: "Insights & Impact", pages: [
    ["/analytics", "Analytics"], ["/impact", "Impact Center"],
    ["/transparency-reports", "Transparency reports"],
  ] },
] as const;

export type NavigationPage = { href: string; label: string; group: string };
export function visibleNavigation(role: string | undefined): NavigationPage[] {
  return navigationGroups.flatMap(group => group.pages
    .filter(([href]) => canAccess(role, href))
    .map(([href, label]) => ({ href, label, group: group.label })));
}

export function activeNavigation(role: string | undefined, pathname: string) {
  // A narrower denied route must never fall back to an allowed parent label.
  if (!canAccess(role, pathname)) return undefined;
  return visibleNavigation(role)
    .filter(page => pathname === page.href || pathname.startsWith(`${page.href}/`) ||
      (pathname === "/" && page.href === "/overview"))
    .sort((a, b) => b.href.length - a.href.length)[0];
}

export function safeFavorites(role: string | undefined, input: unknown): string[] {
  if (!Array.isArray(input)) return [];
  const allowed = new Set(visibleNavigation(role).map(page => page.href));
  return [...new Set(input.filter((value): value is string =>
    typeof value === "string" && allowed.has(value)))].slice(0, 8);
}

export function searchNavigation(role: string | undefined, query: string): NavigationPage[] {
  const words = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return visibleNavigation(role).filter(page => words.every(word =>
    `${page.label} ${page.group}`.toLocaleLowerCase().includes(word)));
}
