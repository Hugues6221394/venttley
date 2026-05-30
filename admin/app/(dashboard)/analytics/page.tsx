import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { StatCard } from "@/components/ui/stat-card";

export const dynamic = "force-dynamic";

type Range = "7d" | "30d" | "90d";

export default async function AnalyticsPage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string }>;
}) {
  const params = await searchParams;
  const range: Range = (params.range as Range) ?? "30d";
  const days = range === "7d" ? 7 : range === "90d" ? 90 : 30;
  const sinceISO = new Date(Date.now() - days * 86400_000).toISOString();
  const prevSinceISO = new Date(Date.now() - 2 * days * 86400_000).toISOString();

  const db = await createAdminClient();
  const [
    metricsRes,
    signupsCurRes,
    signupsPrevRes,
    postsCurRes,
    postsPrevRes,
    commentsCurRes,
    reactionsCurRes,
    categoriesRes,
    regionsRes,
    moderationRes,
    activeUsersRes,
  ] = await Promise.all([
    db.from("admin_metrics_24h").select("*").maybeSingle(),
    db.from("users").select("created_at").gte("created_at", sinceISO).order("created_at"),
    db
      .from("users")
      .select("user_id", { count: "exact", head: true })
      .gte("created_at", prevSinceISO)
      .lt("created_at", sinceISO),
    db.from("posts").select("created_at").gte("created_at", sinceISO).is("deleted_at", null),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .gte("created_at", prevSinceISO)
      .lt("created_at", sinceISO)
      .is("deleted_at", null),
    db.from("posts_comments").select("created_at").gte("created_at", sinceISO),
    db.from("post_likes").select("created_at").gte("created_at", sinceISO),
    db
      .from("posts")
      .select("category_name")
      .gte("created_at", sinceISO)
      .is("deleted_at", null),
    db.from("admin_region_distribution").select("country, users").limit(10),
    db
      .from("reports")
      .select("created_at, resolved_at, is_resolved")
      .gte("created_at", sinceISO),
    db
      .from("posts")
      .select("author_id")
      .gte("created_at", sinceISO)
      .is("deleted_at", null),
  ]);

  const signupsByDay = bucketByDay(
    ((signupsCurRes.data ?? []) as { created_at: string }[]).map((r) => r.created_at),
    days
  );
  const postsByDay = bucketByDay(
    ((postsCurRes.data ?? []) as { created_at: string }[]).map((r) => r.created_at),
    days
  );
  const commentsByDay = bucketByDay(
    ((commentsCurRes.data ?? []) as { created_at: string }[]).map((r) => r.created_at),
    days
  );
  const reactionsByDay = bucketByDay(
    ((reactionsCurRes.data ?? []) as { created_at: string }[]).map((r) => r.created_at),
    days
  );

  const signupsTotal = signupsCurRes.data?.length ?? 0;
  const postsTotal = postsCurRes.data?.length ?? 0;
  const commentsTotal = commentsCurRes.data?.length ?? 0;
  const reactionsTotal = reactionsCurRes.data?.length ?? 0;

  const categoryCounts = countBy(
    ((categoriesRes.data ?? []) as { category_name: string }[]).map((r) => r.category_name)
  );
  const topCategories = [...categoryCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8);

  const dauWriters = new Set(
    ((activeUsersRes.data ?? []) as { author_id: string }[]).map((r) => r.author_id)
  ).size;

  const reports = (moderationRes.data ?? []) as {
    created_at: string;
    resolved_at: string | null;
    is_resolved: boolean;
  }[];
  const resolved = reports.filter((r) => r.is_resolved && r.resolved_at);
  const avgResolutionMinutes =
    resolved.length === 0
      ? null
      : Math.round(
          resolved.reduce((s, r) => {
            const a = new Date(r.created_at).getTime();
            const b = new Date(r.resolved_at!).getTime();
            return s + (b - a);
          }, 0) /
            resolved.length /
            60000
        );

  return (
    <div className="flex flex-col gap-6 max-w-[1400px]">
      <PageHeader
        eyebrow="Insight"
        title="Analytics"
        subtitle={`Platform behaviour over the last ${days} days. Compare against the prior ${days}-day window.`}
        actions={<RangeSwitch active={range} />}
      />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          label={`Signups · ${range}`}
          value={signupsTotal}
          sub="Unique new accounts"
          tone="ok"
          trend={pctChange(signupsTotal, signupsPrevRes.count ?? 0)}
          spark={signupsByDay}
        />
        <StatCard
          label={`Posts · ${range}`}
          value={postsTotal}
          sub="Excludes deleted"
          tone="info"
          trend={pctChange(postsTotal, postsPrevRes.count ?? 0)}
          spark={postsByDay}
        />
        <StatCard
          label={`Comments · ${range}`}
          value={commentsTotal}
          sub={`${commentsTotal && postsTotal ? Math.round((commentsTotal / postsTotal) * 10) / 10 : 0} per post`}
          spark={commentsByDay}
        />
        <StatCard
          label={`Reactions · ${range}`}
          value={reactionsTotal}
          sub="Across all emoji types"
          spark={reactionsByDay}
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card title="Daily signups" hint={`Last ${days} days`}>
          <BarChart data={signupsByDay} days={days} accent="#1F8F4D" />
        </Card>
        <Card title="Daily posts" hint={`Last ${days} days`}>
          <BarChart data={postsByDay} days={days} accent="#D12E65" />
        </Card>
        <Card title="Daily comments" hint={`Last ${days} days`}>
          <BarChart data={commentsByDay} days={days} accent="#3B6AB6" />
        </Card>
        <Card title="Daily reactions" hint={`Last ${days} days`}>
          <BarChart data={reactionsByDay} days={days} accent="#C77A1A" />
        </Card>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <Card title="Top categories" hint={`Posts in last ${days}d`}>
          {topCategories.length === 0 ? (
            <p className="text-sm text-ink-muted italic">No posts yet.</p>
          ) : (
            <ul className="flex flex-col gap-2.5">
              {topCategories.map(([cat, n]) => {
                const max = topCategories[0][1] || 1;
                const pct = Math.round((n / max) * 100);
                return (
                  <li key={cat}>
                    <div className="flex items-center justify-between mb-1">
                      <p className="text-sm font-semibold text-burgundy">{cat}</p>
                      <p className="text-xs text-ink-muted tabular">{n}</p>
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

        <Card title="Top regions" hint="By total user count">
          {(regionsRes.data ?? []).length === 0 ? (
            <p className="text-sm text-ink-muted italic">No location data.</p>
          ) : (
            <ul className="flex flex-col gap-2.5">
              {((regionsRes.data ?? []) as { country: string; users: number }[]).map((r) => {
                const total =
                  ((regionsRes.data ?? []) as { users: number }[]).reduce(
                    (s, x) => s + x.users,
                    0
                  ) || 1;
                const pct = Math.round((r.users / total) * 100);
                return (
                  <li key={r.country}>
                    <div className="flex items-center justify-between mb-1">
                      <p className="text-sm font-semibold text-burgundy">{r.country}</p>
                      <p className="text-xs text-ink-muted tabular">
                        {r.users.toLocaleString()} · {pct}%
                      </p>
                    </div>
                    <div className="h-1.5 rounded-full bg-line overflow-hidden">
                      <div
                        className="h-full bg-info rounded-full"
                        style={{ width: `${Math.max(pct, 4)}%` }}
                      />
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </Card>

        <Card title="Moderation efficiency" hint={`Reports in last ${days}d`}>
          <p className="h-eyebrow">Reports filed</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">{reports.length}</p>
          <p className="h-eyebrow mt-3">Resolved</p>
          <p className="tabular text-2xl font-extrabold text-ok">
            {resolved.length}{" "}
            <span className="text-xs text-ink-muted font-medium">
              ({reports.length > 0 ? Math.round((resolved.length / reports.length) * 100) : 0}%)
            </span>
          </p>
          <p className="h-eyebrow mt-3">Avg resolution time</p>
          <p className="tabular text-lg font-extrabold text-burgundy">
            {avgResolutionMinutes === null
              ? "—"
              : avgResolutionMinutes >= 60
                ? `${Math.round(avgResolutionMinutes / 60)}h ${avgResolutionMinutes % 60}m`
                : `${avgResolutionMinutes}m`}
          </p>
          <p className="h-eyebrow mt-3">Open right now</p>
          <p className="tabular text-2xl font-extrabold text-warn">
            {reports.filter((r) => !r.is_resolved).length}
          </p>
        </Card>
      </div>

      <Card title="Headline metrics" hint="Cross-window">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <Metric label="Total users" value={Number(metricsRes.data?.total_users ?? 0)} />
          <Metric label="DAU (writers, today)" value={dauWriters} />
          <Metric label="Live posts" value={Number(metricsRes.data?.live_posts ?? 0)} />
          <Metric label="Active tribes" value={Number(metricsRes.data?.total_tribes ?? 0)} />
        </div>
      </Card>

      <p className="text-xs text-ink-muted">
        Charts read directly from raw tables. For higher-volume time series,
        wire these aggregates into a materialised view refreshed by pg_cron.
      </p>
    </div>
  );
}

// ─────────────────────── helpers ───────────────────────

function bucketByDay(timestamps: string[], days: number): number[] {
  const buckets = new Array(days).fill(0);
  const now = Date.now();
  for (const t of timestamps) {
    const dayIdx = days - 1 - Math.floor((now - new Date(t).getTime()) / 86400000);
    if (dayIdx >= 0 && dayIdx < days) buckets[dayIdx]++;
  }
  return buckets;
}

function countBy(arr: string[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const x of arr) m.set(x, (m.get(x) ?? 0) + 1);
  return m;
}

function pctChange(now: number, prev: number): number | null {
  if (prev === 0) return now > 0 ? 100 : null;
  return Math.round(((now - prev) / prev) * 100);
}

function BarChart({
  data,
  days,
  accent,
}: {
  data: number[];
  days: number;
  accent: string;
}) {
  const max = Math.max(1, ...data);
  const total = data.reduce((s, x) => s + x, 0);
  return (
    <>
      <div className="flex items-end gap-[3px] h-36">
        {data.map((v, i) => {
          const h = Math.max(2, Math.round((v / max) * 100));
          return (
            <div
              key={i}
              className="flex-1 rounded-sm relative group"
              style={{ height: `${h}%`, background: accent, opacity: 0.85 }}
              title={`day -${days - 1 - i}: ${v}`}
            >
              {v > 0 && (
                <span className="absolute -top-4 left-1/2 -translate-x-1/2 text-[10px] font-bold text-burgundy opacity-0 group-hover:opacity-100">
                  {v}
                </span>
              )}
            </div>
          );
        })}
      </div>
      <p className="text-[11px] text-ink-muted mt-2 tabular">
        Total: {total.toLocaleString()} · Peak: {max.toLocaleString()}/day
      </p>
    </>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <p className="h-eyebrow">{label}</p>
      <p className="tabular text-2xl font-extrabold text-burgundy">
        {value.toLocaleString()}
      </p>
    </div>
  );
}

function RangeSwitch({ active }: { active: Range }) {
  const ranges: Range[] = ["7d", "30d", "90d"];
  return (
    <div className="flex items-center gap-1.5 rounded-lg border border-line bg-white p-1">
      {ranges.map((r) => (
        <Link
          key={r}
          href={`/analytics?range=${r}`}
          className={`px-3 py-1.5 rounded-md text-xs font-bold transition ${
            r === active ? "bg-berry text-white" : "text-ink-muted hover:bg-canvas"
          }`}
        >
          {r}
        </Link>
      ))}
    </div>
  );
}
