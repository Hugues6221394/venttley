import StatCard from "@/components/stat-card";
import { createAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function OverviewPage() {
  const db = createAdminClient();

  const sevenDaysAgo = new Date(
    Date.now() - 7 * 24 * 60 * 60 * 1000
  ).toISOString();
  const twentyFourHoursAgo = new Date(
    Date.now() - 24 * 60 * 60 * 1000
  ).toISOString();

  const [
    { count: userCount },
    { count: tribeCount },
    { count: postCount },
    { count: commentCount },
    { count: usersLast7d },
    { count: postsLast24h },
    { count: pendingReports },
    { count: chatMessages },
  ] = await Promise.all([
    db.from("users").select("user_id", { count: "exact", head: true }),
    db.from("tribes").select("tribe_id", { count: "exact", head: true }),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .is("deleted_at", null),
    db.from("posts_comments").select("comment_id", { count: "exact", head: true }),
    db
      .from("users")
      .select("user_id", { count: "exact", head: true })
      .gte("created_at", sevenDaysAgo),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .gte("created_at", twentyFourHoursAgo)
      .is("deleted_at", null),
    db
      .from("reports")
      .select("report_id", { count: "exact", head: true })
      .eq("is_resolved", false),
    db
      .from("chat_messages")
      .select("message_id", { count: "exact", head: true }),
  ]);

  return (
    <div className="flex flex-col gap-6 max-w-7xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Overview</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          Live platform health across users, tribes, and content.
        </p>
      </div>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard label="Total users" value={userCount ?? 0} sub="Lifetime" />
        <StatCard label="Total tribes" value={tribeCount ?? 0} sub="Including private" />
        <StatCard label="Posts (live)" value={postCount ?? 0} sub="Excludes deleted" />
        <StatCard label="Comments" value={commentCount ?? 0} sub="Lifetime" />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <StatCard
          label="New users · 7d"
          value={usersLast7d ?? 0}
          sub="Joined in the last week"
          tone="ok"
        />
        <StatCard
          label="Posts · 24h"
          value={postsLast24h ?? 0}
          sub="Active venting volume"
        />
        <StatCard
          label="Pending reports"
          value={pendingReports ?? 0}
          sub="Awaiting moderator review"
          tone={(pendingReports ?? 0) > 0 ? "warn" : "ok"}
        />
      </div>

      <div className="card p-6">
        <h2 className="text-base font-extrabold text-burgundy mb-4">
          Conversation health
        </h2>
        <div className="grid grid-cols-2 gap-6">
          <div>
            <p className="text-[11px] font-bold uppercase tracking-widest text-burgundy/60">
              Avg comments / live post
            </p>
            <p className="text-2xl font-extrabold text-berry mt-1">
              {postCount && postCount > 0
                ? Math.round(((commentCount ?? 0) / postCount) * 10) / 10
                : 0}
            </p>
          </div>
          <div>
            <p className="text-[11px] font-bold uppercase tracking-widest text-burgundy/60">
              Lifetime chat messages
            </p>
            <p className="text-2xl font-extrabold text-berry mt-1">
              {(chatMessages ?? 0).toLocaleString()}
            </p>
          </div>
        </div>
      </div>

      <p className="text-xs text-burgundy/55">
        All numbers are pulled with the service-role key — RLS is bypassed
        for this view. Avoid screenshotting this dashboard with stakeholders
        in the room.
      </p>
    </div>
  );
}
