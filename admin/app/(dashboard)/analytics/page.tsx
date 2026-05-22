import { createAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const POSITIVE_MOODS = new Set(["happy", "healing", "hopeful", "grateful"]);
const HEAVY_MOODS = new Set([
  "sad",
  "lonely",
  "angry",
  "broken",
  "anxious",
  "exhausted",
]);

const CATEGORY_LABELS: Record<string, string> = {
  confessions: "Confessions",
  testimonies: "Testimonies",
  relationships: "Relationships",
  family_issues: "Family",
  mental_health: "Mental Health",
  campus_life: "Campus",
  adulting: "Adulting",
  regrets: "Regrets",
  trauma: "Trauma",
  friendship: "Friendship",
  faith_spirituality: "Faith",
  questions: "Questions",
  secrets: "Secrets",
  vent_zone: "Vent Zone",
  dark_thoughts: "Dark Thoughts",
  funny_confessions: "Funny",
  dreams_goals: "Dreams",
  hot_takes: "Hot Takes",
  late_night: "Late Night",
  healing_corner: "Healing Corner",
};

function startOfUtcDay(d: Date) {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
}

export default async function AnalyticsPage() {
  const db = createAdminClient();

  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  const sinceIso = since.toISOString();

  const [
    { data: usersWindow },
    { data: postsWindow },
    { data: topTribes },
  ] = await Promise.all([
    db
      .from("users")
      .select("user_id, created_at")
      .gte("created_at", sinceIso)
      .order("created_at", { ascending: true })
      .limit(5000),
    db
      .from("posts")
      .select("post_id, category_name, post_mood, created_at")
      .is("deleted_at", null)
      .gte("created_at", sinceIso)
      .limit(5000),
    db
      .from("tribes")
      .select("tribe_id, name, slug, category, member_count")
      .order("member_count", { ascending: false })
      .limit(10),
  ]);

  // ------------------------- 30-day new-user series -------------------------
  const userDayBuckets: { date: Date; count: number }[] = [];
  for (let i = 29; i >= 0; i--) {
    const day = new Date(Date.now() - i * 24 * 60 * 60 * 1000);
    userDayBuckets.push({ date: startOfUtcDay(day), count: 0 });
  }
  for (const u of usersWindow ?? []) {
    const d = startOfUtcDay(new Date(u.created_at as string));
    const bucket = userDayBuckets.find(
      (b) => b.date.getTime() === d.getTime()
    );
    if (bucket) bucket.count++;
  }
  const maxUsers = Math.max(1, ...userDayBuckets.map((b) => b.count));
  const totalNewUsers = userDayBuckets.reduce((a, b) => a + b.count, 0);

  // ------------------------- Category breakdown -------------------------
  const categoryCounts = new Map<string, number>();
  for (const p of postsWindow ?? []) {
    const c = (p as { category_name: string }).category_name ?? "other";
    categoryCounts.set(c, (categoryCounts.get(c) ?? 0) + 1);
  }
  const sortedCategories = Array.from(categoryCounts.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8);
  const maxCategoryCount = Math.max(1, ...sortedCategories.map(([, n]) => n));

  // ------------------------- Sentiment per 7-day window -------------------
  const weekBuckets: { label: string; pos: number; neu: number; heavy: number }[] = [];
  for (let w = 3; w >= 0; w--) {
    const from = new Date(Date.now() - (w + 1) * 7 * 24 * 60 * 60 * 1000);
    const to = new Date(Date.now() - w * 7 * 24 * 60 * 60 * 1000);
    let pos = 0, neu = 0, heavy = 0;
    for (const p of postsWindow ?? []) {
      const t = new Date(p.created_at as string).getTime();
      if (t >= from.getTime() && t < to.getTime()) {
        const mood = (p as { post_mood?: string }).post_mood ?? "";
        if (POSITIVE_MOODS.has(mood)) pos++;
        else if (HEAVY_MOODS.has(mood)) heavy++;
        else neu++;
      }
    }
    weekBuckets.push({
      label: `${w === 0 ? "This wk" : `${w}w ago`}`,
      pos,
      neu,
      heavy,
    });
  }

  return (
    <div className="flex flex-col gap-6 max-w-6xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Analytics</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          Trailing 30 days of platform behaviour, drawn directly from posts +
          users.
        </p>
      </div>

      {/* 30-day new users line/bars */}
      <section className="card p-5">
        <div className="flex items-baseline justify-between">
          <h2 className="text-base font-extrabold text-burgundy">
            New users · last 30 days
          </h2>
          <p className="text-xs text-burgundy/60">{totalNewUsers} joined</p>
        </div>
        <div className="mt-4 h-32 flex items-end gap-[3px]">
          {userDayBuckets.map((b, i) => {
            const h = (b.count / maxUsers) * 100;
            return (
              <div
                key={i}
                className="flex-1 rounded-sm bg-berry/80 transition"
                style={{ height: `${Math.max(2, h)}%` }}
                title={`${b.date.toISOString().slice(0, 10)} · ${b.count}`}
              />
            );
          })}
        </div>
        <div className="mt-2 flex justify-between text-[10px] text-burgundy/55">
          <span>{userDayBuckets[0].date.toISOString().slice(5, 10)}</span>
          <span>
            {userDayBuckets[userDayBuckets.length - 1].date
              .toISOString()
              .slice(5, 10)}
          </span>
        </div>
      </section>

      {/* Sentiment trend */}
      <section className="card p-5">
        <h2 className="text-base font-extrabold text-burgundy mb-1">
          Sentiment trend
        </h2>
        <p className="text-xs text-burgundy/55">
          Rolling 4-week breakdown of post moods.
        </p>
        <div className="mt-4 flex flex-col gap-3">
          {weekBuckets.map((b) => {
            const total = b.pos + b.neu + b.heavy || 1;
            return (
              <div key={b.label}>
                <div className="flex justify-between text-[11px] font-semibold text-burgundy/65 mb-1">
                  <span>{b.label}</span>
                  <span>{b.pos + b.neu + b.heavy} posts</span>
                </div>
                <div className="h-3 rounded-full overflow-hidden flex">
                  <div
                    className="bg-ok"
                    style={{ width: `${(b.pos / total) * 100}%` }}
                    title={`${b.pos} hopeful`}
                  />
                  <div
                    className="bg-warn"
                    style={{ width: `${(b.neu / total) * 100}%` }}
                    title={`${b.neu} pensive`}
                  />
                  <div
                    className="bg-berry"
                    style={{ width: `${(b.heavy / total) * 100}%` }}
                    title={`${b.heavy} heavy`}
                  />
                </div>
              </div>
            );
          })}
        </div>
        <div className="mt-4 flex gap-4 text-[11px] font-semibold">
          <span className="inline-flex items-center gap-1">
            <span className="h-2 w-2 rounded-full bg-ok" /> Hopeful
          </span>
          <span className="inline-flex items-center gap-1">
            <span className="h-2 w-2 rounded-full bg-warn" /> Pensive
          </span>
          <span className="inline-flex items-center gap-1">
            <span className="h-2 w-2 rounded-full bg-berry" /> Heavy
          </span>
        </div>
      </section>

      {/* Category breakdown */}
      <section className="card p-5">
        <h2 className="text-base font-extrabold text-burgundy mb-1">
          Top categories
        </h2>
        <p className="text-xs text-burgundy/55">
          Posts in each channel, last 30 days.
        </p>
        <div className="mt-4 flex flex-col gap-2">
          {sortedCategories.length === 0 && (
            <p className="text-sm italic text-burgundy/55">
              No posts in the last 30 days.
            </p>
          )}
          {sortedCategories.map(([cat, count]) => (
            <div key={cat} className="flex items-center gap-3">
              <p className="w-32 text-sm font-semibold text-burgundy/80">
                {CATEGORY_LABELS[cat] ?? cat}
              </p>
              <div className="flex-1 h-3 rounded-full bg-mauve/25 overflow-hidden">
                <div
                  className="h-full bg-berry"
                  style={{ width: `${(count / maxCategoryCount) * 100}%` }}
                />
              </div>
              <p className="w-10 text-right text-sm font-bold text-burgundy/80">
                {count}
              </p>
            </div>
          ))}
        </div>
      </section>

      {/* Top tribes */}
      <section className="card p-5">
        <h2 className="text-base font-extrabold text-burgundy mb-3">
          Top tribes by membership
        </h2>
        <ol className="flex flex-col gap-2 list-decimal pl-5">
          {(topTribes ?? []).map((t) => (
            <li
              key={t.tribe_id as string}
              className="flex items-center justify-between"
            >
              <span className="font-semibold text-burgundy">{String(t.name)}</span>
              <span className="text-sm text-burgundy/70">
                {Number(t.member_count).toLocaleString()} members
              </span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}
