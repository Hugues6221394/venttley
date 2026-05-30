import Link from "next/link";
import { notFound } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import {
  ChevronLeft,
  Sparkles,
  Users2,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

async function toggleFeatured(formData: FormData) {
  "use server";
  const id = String(formData.get("tribe_id") ?? "");
  const featured = String(formData.get("featured") ?? "") === "true";
  await rpc("admin_set_tribe_featured", {
    p_tribe: id,
    p_featured: featured,
    p_reason: null,
  });
  revalidatePath(`/tribes/${id}`);
}

export default async function TribeDetailPage({
  params,
}: {
  params: Promise<{ tribeId: string }>;
}) {
  const { tribeId } = await params;
  const db = createAdminClient();

  const { data: tribe } = await db
    .from("tribes")
    .select(
      "tribe_id, name, slug, description, category, is_private, is_featured, member_count, keeper_id, created_at"
    )
    .eq("tribe_id", tribeId)
    .maybeSingle();

  if (!tribe) notFound();

  const since30d = new Date(Date.now() - 30 * 86400 * 1000).toISOString();
  const [
    { data: keeper },
    { count: postCount30d },
    { data: topPosters },
    { data: recentPosts },
  ] = await Promise.all([
    tribe.keeper_id
      ? db
          .from("users")
          .select("user_id, anonymous_pseudonym, avatar_seed")
          .eq("user_id", tribe.keeper_id)
          .maybeSingle()
      : Promise.resolve({ data: null }),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .eq("tribe_id", tribeId)
      .gte("created_at", since30d)
      .is("deleted_at", null),
    db
      .from("posts")
      .select("author_id")
      .eq("tribe_id", tribeId)
      .gte("created_at", since30d)
      .is("deleted_at", null)
      .limit(500),
    db
      .from("feed_posts")
      .select("post_id, content, author_pseudonym, created_at, likes_count, comments_count, crisis_level")
      .eq("tribe_id", tribeId)
      .order("created_at", { ascending: false })
      .limit(10),
  ]);

  const posterCounts = new Map<string, number>();
  for (const p of ((topPosters ?? []) as { author_id: string }[])) {
    posterCounts.set(p.author_id, (posterCounts.get(p.author_id) ?? 0) + 1);
  }
  const topPosterIds = [...posterCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);
  const { data: topPosterRows } =
    topPosterIds.length > 0
      ? await db
          .from("users")
          .select("user_id, anonymous_pseudonym")
          .in(
            "user_id",
            topPosterIds.map((p) => p[0])
          )
      : { data: [] };

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <div>
        <Link href="/tribes" className="btn-ghost mb-3">
          <ChevronLeft size={14} /> Tribes
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-4">
            <div className="h-14 w-14 rounded-2xl bg-berry/15 text-berry flex items-center justify-center text-xl font-extrabold">
              {tribe.name.slice(0, 2).toUpperCase()}
            </div>
            <div>
              <h1 className="h-page">{tribe.name}</h1>
              <div className="flex flex-wrap items-center gap-2 mt-1.5">
                <Badge tone="neutral">/{tribe.slug}</Badge>
                <Badge tone="info">{tribe.category}</Badge>
                {tribe.is_featured && (
                  <Badge tone="info" icon={<Sparkles size={11} />}>
                    featured
                  </Badge>
                )}
                {tribe.is_private && <Badge tone="warn">private</Badge>}
              </div>
            </div>
          </div>
          <form action={toggleFeatured}>
            <input type="hidden" name="tribe_id" value={tribeId} />
            <input
              type="hidden"
              name="featured"
              value={tribe.is_featured ? "false" : "true"}
            />
            <button type="submit" className="btn-secondary">
              <Sparkles size={14} />
              {tribe.is_featured ? "Unfeature" : "Feature"}
            </button>
          </form>
        </div>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Card padded>
          <p className="h-eyebrow mb-1">Members</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">
            {tribe.member_count.toLocaleString()}
          </p>
        </Card>
        <Card padded>
          <p className="h-eyebrow mb-1">Posts · 30d</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">
            {(postCount30d ?? 0).toLocaleString()}
          </p>
        </Card>
        <Card padded>
          <p className="h-eyebrow mb-1">Unique posters · 30d</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">
            {posterCounts.size}
          </p>
        </Card>
        <Card padded>
          <p className="h-eyebrow mb-1">Age</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">
            {Math.max(
              1,
              Math.round(
                (Date.now() - new Date(tribe.created_at).getTime()) /
                  86400000
              )
            )}
            d
          </p>
        </Card>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="flex flex-col gap-6">
          <Card title="Keeper" padded>
            {tribe.keeper_id && keeper ? (
              <div className="flex items-center gap-3">
                <div className="h-10 w-10 rounded-xl bg-berry text-white flex items-center justify-center font-extrabold">
                  {(keeper as { anonymous_pseudonym: string }).anonymous_pseudonym.slice(0, 2).toUpperCase()}
                </div>
                <div className="flex-1">
                  <Link
                    href={`/users/${(keeper as { user_id: string }).user_id}`}
                    className="font-bold text-burgundy hover:text-berry"
                  >
                    @{(keeper as { anonymous_pseudonym: string }).anonymous_pseudonym}
                  </Link>
                </div>
                <Link
                  href={`/users/${(keeper as { user_id: string }).user_id}`}
                  className="btn-ghost"
                >
                  Open
                </Link>
              </div>
            ) : (
              <p className="text-sm text-ink-muted italic">No keeper assigned.</p>
            )}
          </Card>

          <Card title="Facts" padded>
            <KV label="Tribe ID" value={<span className="font-mono text-xs">{tribe.tribe_id}</span>} />
            <KV label="Slug" value={`/${tribe.slug}`} />
            <KV label="Category" value={tribe.category} />
            <KV label="Visibility" value={tribe.is_private ? "private" : "public"} />
            <KV label="Created" value={new Date(tribe.created_at).toLocaleString()} />
            {tribe.description && (
              <div className="py-2">
                <p className="h-eyebrow">Description</p>
                <p className="text-sm text-burgundy mt-1">{tribe.description}</p>
              </div>
            )}
          </Card>

          <Card title="Top posters · 30d" padded={false}>
            {topPosterIds.length === 0 ? (
              <div className="px-5 py-6 text-sm text-ink-muted italic">
                No posts in the last 30 days.
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {topPosterIds.map(([uid, count]) => {
                  const u = ((topPosterRows ?? []) as { user_id: string; anonymous_pseudonym: string }[]).find((x) => x.user_id === uid);
                  return (
                    <li
                      key={uid}
                      className="px-5 py-2.5 flex items-center justify-between"
                    >
                      <Link
                        href={`/users/${uid}`}
                        className="text-sm font-semibold text-burgundy hover:text-berry"
                      >
                        @{u?.anonymous_pseudonym ?? "—"}
                      </Link>
                      <span className="text-xs text-ink-muted tabular">
                        {count} posts
                      </span>
                    </li>
                  );
                })}
              </ul>
            )}
          </Card>
        </div>

        <div className="lg:col-span-2">
          <Card title="Recent posts" hint="Last 10 posts in this tribe" padded={false}>
            {((recentPosts ?? []) as unknown[]).length === 0 ? (
              <div className="px-5 py-10 text-sm text-ink-muted italic">
                No posts yet.
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {((recentPosts ?? []) as {
                  post_id: string;
                  content: string;
                  author_pseudonym: string;
                  created_at: string;
                  likes_count: number;
                  comments_count: number;
                  crisis_level: string | null;
                }[]).map((p) => (
                  <li key={p.post_id} className="px-5 py-3">
                    <div className="flex items-center gap-2 mb-1">
                      <p className="text-sm font-bold text-burgundy">
                        {p.author_pseudonym}
                      </p>
                      {p.crisis_level && (
                        <Badge tone="crisis">crisis · {p.crisis_level}</Badge>
                      )}
                      <p className="text-[11px] text-ink-muted ml-auto">
                        {new Date(p.created_at).toLocaleString()}
                      </p>
                    </div>
                    <p className="text-sm text-burgundy line-clamp-3">
                      {p.content}
                    </p>
                    <p className="text-[11px] text-ink-muted mt-1">
                      ♡ {p.likes_count} · 💬 {p.comments_count}
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
      </div>
    </div>
  );
}
