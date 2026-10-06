import { canAccess } from "./roles";

// Static page metadata only. Never include member identifiers, query strings,
// case content, or database search results in navigation or browser preferences.
// The pinned group is the daily work every role starts from; it is always
// expanded. The rest is ordered by how often staff need it.
export const navigationGroups = [
  { label: "Daily work", pinned: true, pages: [
    ["/overview", "Home"], ["/inbox", "Inbox"], ["/users", "Members"],
    ["/moderation", "Moderation"], ["/appeals", "Appeals"], ["/support/cases", "Support"],
  ] },
  { label: "Safety", pages: [
    ["/safety", "Safety & Crisis"], ["/incidents", "Incident command"],
    ["/csam", "CSAM incidents"], ["/youth-safety", "Youth safety"],
    ["/media", "Media safety"], ["/moderation/campaigns", "Harm campaigns"],
    ["/moderation/abuse", "Abuse intelligence"], ["/integrity", "Platform integrity"],
    ["/feed-integrity", "Feed integrity"], ["/crisis/playbooks", "Crisis playbooks"],
  ] },
  { label: "Moderation setup", pages: [
    ["/queue-control", "Queue control"], ["/automod", "Automod rules"],
    ["/moderation/policies", "Policy center"], ["/moderation/quality", "Moderation quality"],
    ["/moderation/workforce", "Moderation workforce"],
  ] },
  { label: "Community", pages: [
    ["/tribes", "Tribes"], ["/tribe-governance", "Tribe governance"],
    ["/content", "Content explorer"], ["/verification", "Verification queue"],
    ["/broadcasts", "Broadcasts"], ["/music", "Music catalog"],
    ["/feedback", "Bugs & suggestions"],
  ] },
  { label: "Insights", pages: [
    ["/analytics", "Analytics"], ["/impact", "Impact Center"],
    ["/transparency-reports", "Transparency reports"],
  ] },
  { label: "Platform", pages: [
    ["/system", "System health"], ["/slo", "Service levels"], ["/releases", "Release readiness"],
    ["/flags", "Feature flags"], ["/experiments", "Experiments"],
    ["/jobs", "Jobs & delivery"], ["/delivery", "Delivery operations"],
    ["/messaging-operations", "Messaging operations"], ["/storage-operations", "Storage operations"],
    ["/model-operations", "Model operations"], ["/recovery-readiness", "Recovery readiness"],
    ["/ops", "Ops & cost"],
  ] },
  { label: "Staff & access", pages: [
    ["/staff", "Staff accounts"], ["/staff/invitations", "Staff invitations"],
    ["/staff/access-reviews", "Staff access reviews"], ["/roles", "Roles & permissions"],
    ["/approvals", "Sensitive approvals"], ["/sessions", "Sessions & IPs"],
    ["/emergency-access", "Emergency access"], ["/audit", "Audit log"],
    ["/settings", "Settings"],
  ] },
  { label: "Compliance", pages: [
    ["/privacy", "Privacy requests"], ["/legal-requests", "Legal requests"],
    ["/evidence-access", "Evidence access"], ["/data-governance", "Data governance"],
    ["/regional-compliance", "Regional compliance"], ["/policy/versions", "Policy versions"],
  ] },
] as const;

export const isPinnedGroup = (label: string | undefined) =>
  navigationGroups.some(group => group.label === label && "pinned" in group);

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
