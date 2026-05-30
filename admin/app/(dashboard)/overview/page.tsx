import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader, SectionHeader } from "@/components/ui/page-header";
import { StatCard, Sparkline } from "@/components/ui/stat-card";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/section";
import { EmptyState } from "@/components/ui/empty-state";
import {
  AlertTriangle,
  CheckCircle2,
  ChevronRight,
  Clock,
  ExternalLink,
  Heart,
  ShieldAlert,
  Sparkles,
  TrendingUp,
  Users,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type RegionRow = { country: string; users: number };
type HourlyRow = { hour: string; signups?: number; posts?: number };
type DailyReportRow = { day: string; reports: number };
type IncidentRow = {
  post_id: string;
  content: string;
  crisis_level: "elevated" | "high";
  author_pseudonym: string;
  created_at: string;
};
type AuditRow = {
  audit_id: string;
  actor_pseudonym: string;
  action: string;
  target_label: string | null;
  created_at: string;
};

export default async function OverviewPage() {
  const db = await createAdminClient();

  // One round-trip per dataset — kept narrow on purpose so the page
  // is fast and predictable.
  const [
    metricsRes,
    signupsRes,
    postsHourlyRes,
    reportsDailyRes,
    regionsRes,
    incidentsRes,
    auditRes,
    prevSignupsRes,
    prevPostsRes,
  ] = await Promise.all([
    db.from("admin_metrics_24h").select("*").maybeSingle(),
    db.from("admin_signups_hourly").select("hour, signups"),
    db.from("admin_posts_hourly").select("hour, posts"),
    db.from("admin_reports_daily").select("day, reports"),
    db.from("admin_region_distribution").select("country, users").limit(8),
    db
      .from("feed_posts")
      .select("post_id, content, crisis_level, author_pseudonym, created_at")
      .not("crisis_level", "is", null)
      .order("created_at", { ascending: false })
      .limit(5),
    db
      .from("audit_log")
      .select("audit_id, actor_pseudonym, action, target_label, created_at")
      .order("created_at", { ascending: false })
      .limit(8),
    // Comparison windows: 24-48h ago signups and posts so we can show trends.
    db
      .from("users")
      .select("user_id", { count: "exact", head: true })
      .gte("created_at", new Date(Date.now() - 48 * 3600 * 1000).toISOString())
      .lt("created_at", new Date(Date.now() - 24 * 3600 * 1000).toISOString()),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .gte("created_at", new Date(Date.now() - 48 * 3600 * 1000).toISOString())
      .lt("created_at", new Date(Date.now() - 24 * 3600 * 1000).toISOString())
      .is("deleted_at", null),
  ]);

  const m = metricsRes.data ?? {
    total_users: 0,
    new_users_24h: 0,
    new_users_7d: 0,
    dau_posters: 0,
    dau_commenters: 0,
    total_tribes: 0,
    live_posts: 0,
    posts_24h: 0,
    comments_24h: 0,
    open_reports: 0,
    crisis_posts_24h: 0,
    active_broadcasts: 0,
  };

  const signupsSpark = fill24h(
    (signupsRes.data ?? []) as HourlyRow[],
    (r) => r.signups ?? 0
  );
  const postsSpark = fill24h(
    (postsHourlyRes.data ?? []) as HourlyRow[],
    (r) => r.posts ?? 0
  );
  const dau = (m.dau_posters ?? 0) + (m.dau_commenters ?? 0);

  const signupsTrend = pctChange(
    Number(m.new_users_24h ?? 0),
    prevSignupsRes.count ?? 0
  );
  const postsTrend = pctChange(
    Number(m.posts_24h ?? 0),
    prevPostsRes.count ?? 0
  );

  const regions = (regionsRes.data ?? []) as RegionRow[];
  const reports = (reportsDailyRes.data ?? []) as DailyReportRow[];
  const incidents = (incidentsRes.data ?? []) as IncidentRow[];
  const audit = (auditRes.data ?? []) as AuditRow[];

  return (
    <div className="flex flex-col gap-8 max-w-[1400px]">
      <PageHeader
        eyebrow="Operate"
        title="Control Center"
        subtitle="Live state of the platform: users, content, safety. Anything urgent surfaces here."
        actions={
          <Link href="/audit" className="btn-secondary">
            View audit log
            <ChevronRight size={14} />
          </Link>
        }
      />

      {/* ─────────── Critical pulse strip ─────────── */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          label="Total users"
          value={Number(m.total_users ?? 0)}
          sub={`+${m.new_users_7d ?? 0} in last 7d`}
          spark={signupsSpark}
        />
        <StatCard
          label="DAU (writers)"
          value={dau}
          sub={`${m.dau_posters ?? 0} posters · ${m.dau_commenters ?? 0} commenters`}
          tone="info"
          spark={postsSpark}
        />
        <StatCard
          label="New signups · 24h"
          value={Number(m.new_users_24h ?? 0)}
          sub="vs prior 24h"
          tone="ok"
          trend={signupsTrend}
        />
        <StatCard
          label="Posts · 24h"
          value={Number(m.posts_24h ?? 0)}
          sub={`${m.comments_24h ?? 0} comments today`}
          trend={postsTrend}
        />
      </div>

      {/* ─────────── Safety strip ─────────── */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          label="Pending reports"
          value={Number(m.open_reports ?? 0)}
          sub="Awaiting moderator review"
          tone={Number(m.open_reports) > 0 ? "warn" : "ok"}
          href="/moderation"
        />
        <StatCard
          label="Crisis posts · 24h"
          value={Number(m.crisis_posts_24h ?? 0)}
          sub="Surfaced helpline banner"
          tone={Number(m.crisis_posts_24h) > 0 ? "crisis" : "ok"}
        />
        <StatCard
          label="Active broadcasts"
          value={Number(m.active_broadcasts ?? 0)}
          sub="Currently visible to users"
          href="/broadcasts"
          tone="info"
        />
        <StatCard
          label="Live posts"
          value={Number(m.live_posts ?? 0)}
          sub={`${m.total_tribes ?? 0} tribes`}
        />
      </div>

      {/* ─────────── Two-column body ─────────── */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* LEFT: Incidents + audit */}
        <div className="lg:col-span-2 flex flex-col gap-6">
          <Card
            title="Posts surfacing crisis helplines"
            hint="Self-harm / suicidal-ideation signals from the safety classifier, last 24h"
            actions={
              <Link href="/moderation?tab=crisis" className="btn-ghost">
                Open queue <ChevronRight size={14} />
              </Link>
            }
            padded={false}
          >
            {incidents.length === 0 ? (
              <div className="px-5 py-10">
                <EmptyState
                  icon={<CheckCircle2 size={28} />}
                  title="No crisis-tagged posts in the last 24 hours."
                  hint="The classifier is running. This list will populate the moment a flagged post is created."
                />
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {incidents.map((p) => (
                  <li
                    key={p.post_id}
                    className="px-5 py-3 hover:bg-canvas/70 transition flex items-start gap-3"
                  >
                    <Badge
                      tone={p.crisis_level === "high" ? "crisis" : "danger"}
                      icon={<Heart size={11} fill="currentColor" />}
                    >
                      {p.crisis_level}
                    </Badge>
                    <div className="min-w-0 flex-1">
                      <p className="text-sm text-burgundy line-clamp-2">
                        {p.content}
                      </p>
                      <p className="text-[11px] text-ink-muted mt-1">
                        {p.author_pseudonym} · {timeAgo(p.created_at)}
                      </p>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card
            title="Recent admin actions"
            hint="Every privileged write is audit-logged. Tap an entry for context."
            actions={
              <Link href="/audit" className="btn-ghost">
                View all <ChevronRight size={14} />
              </Link>
            }
            padded={false}
          >
            {audit.length === 0 ? (
              <div className="px-5 py-10">
                <EmptyState
                  icon={<Sparkles size={28} />}
                  title="No actions yet — your audit ledger is empty."
                  hint="Suspend a user, send a broadcast, or toggle a flag. Every move lands here."
                />
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {audit.map((a) => (
                  <li
                    key={a.audit_id}
                    className="px-5 py-3 flex items-center gap-3"
                  >
                    <Badge tone={actionTone(a.action)}>{a.action}</Badge>
                    <div className="min-w-0 flex-1">
                      <p className="text-sm text-burgundy truncate">
                        {a.target_label ?? "—"}
                      </p>
                      <p className="text-[11px] text-ink-muted">
                        by {a.actor_pseudonym} · {timeAgo(a.created_at)}
                      </p>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>

        {/* RIGHT: Regions + reports trend + ops shortcuts */}
        <div className="flex flex-col gap-6">
          <Card title="Top regions" hint="By total signed-up users">
            {regions.length === 0 ? (
              <p className="text-sm text-ink-muted italic">
                No location data yet.
              </p>
            ) : (
              <ul className="flex flex-col gap-2.5">
                {regions.map((r) => {
                  const total = regions.reduce((s, x) => s + x.users, 0) || 1;
                  const pct = Math.round((r.users / total) * 100);
                  return (
                    <li key={r.country}>
                      <div className="flex items-center justify-between mb-1">
                        <p className="text-sm font-semibold text-burgundy">
                          {r.country}
                        </p>
                        <p className="text-xs text-ink-muted tabular">
                          {r.users.toLocaleString()} · {pct}%
                        </p>
                      </div>
                      <div className="h-1.5 rounded-full bg-line overflow-hidden">
                        <div
                          className="h-full bg-berry rounded-full"
                          style={{ width: `${Math.max(pct, 4)}%` }}
                        />
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </Card>

          <Card title="Reports · last 30d" hint="Volume per day">
            <div className="flex items-end gap-1.5 h-24">
              {fillDays(reports, 30).map((d, i) => {
                const max = Math.max(
                  1,
                  ...reports.map((x) => x.reports),
                  1
                );
                const h = Math.round((d.reports / max) * 100);
                return (
                  <div
                    key={i}
                    className="flex-1 bg-berry/15 rounded-sm relative group"
                    style={{ height: `${Math.max(h, 3)}%` }}
                    title={`${d.day.slice(0, 10)} · ${d.reports} reports`}
                  >
                    {d.reports > 0 && (
                      <span className="absolute -top-5 left-1/2 -translate-x-1/2 text-[10px] text-ink-muted opacity-0 group-hover:opacity-100">
                        {d.reports}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>
            <p className="text-[11px] text-ink-muted mt-2">
              Total: {reports.reduce((s, x) => s + x.reports, 0)} ·{" "}
              {reports.length > 0 ? `peak ${Math.max(...reports.map((x) => x.reports))}/day` : "no data"}
            </p>
          </Card>

          <Card title="Operations" padded={false}>
            <ul className="divide-y divide-line">
              <OpsLink
                href="/moderation"
                title="Triage moderation queue"
                hint={`${m.open_reports ?? 0} pending`}
                icon={<ShieldAlert size={16} className="text-berry" />}
              />
              <OpsLink
                href="/broadcasts"
                title="Send a broadcast"
                hint="Reach users by region, tribe, or role"
                icon={<TrendingUp size={16} className="text-berry" />}
              />
              <OpsLink
                href="/users"
                title="Find a user"
                hint="By pseudonym, status, or role"
                icon={<Users size={16} className="text-berry" />}
              />
              <OpsLink
                href="/system"
                title="Inspect system health"
                hint="DB, classifier, Redis"
                icon={<AlertTriangle size={16} className="text-berry" />}
              />
            </ul>
          </Card>
        </div>
      </div>

      <p className="text-xs text-ink-muted">
        Numbers refresh on every page load. The hourly views read{" "}
        <code className="font-mono">admin_metrics_24h</code> and friends
        (migration 0022).
      </p>
    </div>
  );
}

// ───────────────────────── helpers ─────────────────────────

function pctChange(now: number, prev: number): number | null {
  if (prev === 0) return now > 0 ? 100 : null;
  return Math.round(((now - prev) / prev) * 100);
}

function fill24h(
  rows: HourlyRow[],
  pick: (r: HourlyRow) => number
): number[] {
  const buckets: number[] = new Array(24).fill(0);
  const now = Date.now();
  for (const r of rows) {
    const hourMs = new Date(r.hour).getTime();
    const idx = 23 - Math.floor((now - hourMs) / 3600_000);
    if (idx >= 0 && idx < 24) buckets[idx] = pick(r);
  }
  return buckets;
}

function fillDays(
  rows: DailyReportRow[],
  days: number
): { day: string; reports: number }[] {
  const map = new Map<string, number>();
  for (const r of rows) {
    const key = r.day.slice(0, 10);
    map.set(key, r.reports);
  }
  const out: { day: string; reports: number }[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(Date.now() - i * 86400_000).toISOString().slice(0, 10);
    out.push({ day: d, reports: map.get(d) ?? 0 });
  }
  return out;
}

function timeAgo(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function actionTone(action: string): "ok" | "warn" | "danger" | "info" | "neutral" {
  if (action.includes("delete") || action.includes("ban") || action.includes("suspend"))
    return "danger";
  if (action.includes("restore") || action.includes("resolve")) return "ok";
  if (action.includes("flag") || action.includes("role") || action.includes("broadcast"))
    return "info";
  if (action.includes("warn")) return "warn";
  return "neutral";
}

function OpsLink({
  href,
  title,
  hint,
  icon,
}: {
  href: string;
  title: string;
  hint: string;
  icon: React.ReactNode;
}) {
  return (
    <li>
      <Link
        href={href}
        className="flex items-center gap-3 px-4 py-3 hover:bg-canvas/70 transition"
      >
        <span className="h-8 w-8 rounded-lg bg-berry/10 flex items-center justify-center">
          {icon}
        </span>
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-burgundy">{title}</p>
          <p className="text-xs text-ink-muted">{hint}</p>
        </div>
        <ChevronRight size={14} className="text-ink-muted" />
      </Link>
    </li>
  );
}
