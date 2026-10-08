import Link from "next/link";
import { notFound } from "next/navigation";
import {
  createAdminClient,
  createSsrClient,
} from "@/lib/supabase/server";
import { POST_AUTHOR_EMBED, withAuthorPseudonym } from "@/lib/admin-posts";
import { WorkflowForm } from "@/components/workflows/workflow-form";
import { setTribeActive, setTribeFeatured, setTribeKeeper, addTribeMember, removeTribeMember, restoreTribe } from "@/lib/content-actions";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import {
  ChevronLeft,
  Sparkles,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

export default async function TribeDetailPage({
  params,
}: {
  params: Promise<{ tribeId: string }>;
}) {
  const { tribeId } = await params;
  const db = await createAdminClient();
  const ssr = await createSsrClient();
  const {
    data: { user: actor },
  } = await ssr.auth.getUser();
  const { data: actorProfile } = actor
    ? await ssr
        .from("users")
        .select("user_role")
        .eq("user_id", actor.id)
        .maybeSingle()
    : { data: null };
  const canManage =
    actorProfile?.user_role === "super_admin" ||
    actorProfile?.user_role === "admin";

  const { data: tribe } = await db
    .from("tribes")
    .select(
      "tribe_id, name, slug, description, category, is_private, is_featured, is_active, member_count, keeper_id, created_at, lifecycle_status, lifecycle_reason, deletion_requested_at, deletion_purge_at"
    )
    .eq("tribe_id", tribeId)
    .maybeSingle();

  if (!tribe) notFound();

  const { data: members } = await db
    .from("tribe_members")
    .select("user_id, role, joined_at, users(anonymous_pseudonym)")
    .eq("tribe_id", tribeId)
    .order("role", { ascending: true })
    .limit(250);

  const since30d = new Date(Date.now() - 30 * 86400 * 1000).toISOString();
  const [
    { data: keeper },
    { count: postCount30d },
    { data: topPosters },
    { data: recentPostRows },
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
      .from("posts")
      .select(`post_id, content, created_at, likes_count, comments_count, crisis_level, ${POST_AUTHOR_EMBED}`)
      .eq("tribe_id", tribeId)
      .order("created_at", { ascending: false })
      .limit(10),
  ]);
  const recentPosts = withAuthorPseudonym(recentPostRows);

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
                <Badge tone={tribe.is_active ? "ok" : "danger"}>
                  {tribe.is_active ? "active" : "deactivated"}
                </Badge>
                {tribe.lifecycle_status &&
                  tribe.lifecycle_status !==
                    (tribe.is_active ? "active" : "paused") && (
                    <Badge
                      tone={
                        tribe.lifecycle_status === "pending_deletion"
                          ? "danger"
                          : "warn"
                      }
                    >
                      {tribe.lifecycle_status.replaceAll("_", " ")}
                    </Badge>
                  )}
              </div>
            </div>
          </div>
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
          {canManage && <Card title="Tribe actions" hint="Each needs a reason and is audited" padded>
            <div className="flex flex-col gap-4">
              <WorkflowForm action={setTribeActive} blockUncertainRetry label={tribe.is_active ? "Deactivate tribe" : "Reactivate tribe"}
                confirmation={tribe.is_active ? "Hides the tribe and stops all posting in it. Members keep their membership and nothing is deleted." : "Makes the tribe visible again and lets members post."}>
                <input type="hidden" name="tribe_id" value={tribeId} /><input type="hidden" name="active" value={tribe.is_active ? "false" : "true"} />
                <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} /></label>
              </WorkflowForm>
              <WorkflowForm action={setTribeFeatured} blockUncertainRetry label={tribe.is_featured ? "Stop featuring" : "Feature tribe"}
                confirmation={tribe.is_featured ? "Removes the tribe from the featured list." : "Shows the tribe in the featured list for every member."}>
                <input type="hidden" name="tribe_id" value={tribeId} /><input type="hidden" name="featured" value={tribe.is_featured ? "false" : "true"} />
                <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} /></label>
              </WorkflowForm>
              {tribe.lifecycle_status === "pending_deletion" && tribe.deletion_purge_at && new Date(tribe.deletion_purge_at).getTime() > Date.now() &&
                <WorkflowForm action={restoreTribe} blockUncertainRetry label="Restore tribe" confirmation="Cancels the deletion and brings back the tribe with its members and posts.">
                  <input type="hidden" name="tribe_id" value={tribeId} />
                  <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} defaultValue="Recovered during the 30-day deletion window" /></label>
                </WorkflowForm>}
            </div>
          </Card>}
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
            {canManage && <div className="mt-4 pt-4 border-t border-line">
              <WorkflowForm action={setTribeKeeper} blockUncertainRetry label="Change keeper" confirmation="The new keeper can approve members and moderate this tribe. The current keeper becomes a regular member.">
                <input type="hidden" name="tribe_id" value={tribeId} />
                <label className="contact-field"><span>New keeper (handle or user ID)</span><input name="member" className="input" required maxLength={60} placeholder="@handle" /></label>
                <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. keeper asked to step down" /></label>
              </WorkflowForm>
            </div>}
          </Card>

          <Card title="Facts" padded>
            <KV label="Tribe ID" value={<span className="font-mono text-xs">{tribe.tribe_id}</span>} />
            <KV label="Slug" value={`/${tribe.slug}`} />
            <KV label="Category" value={tribe.category} />
            <KV label="Visibility" value={tribe.is_private ? "private" : "public"} />
            <KV
              label="Lifecycle"
              value={tribe.lifecycle_status?.replaceAll("_", " ") ?? "active"}
            />
            {tribe.deletion_purge_at && (
              <KV
                label="Recovery ends"
                value={new Date(tribe.deletion_purge_at).toLocaleString()}
              />
            )}
            {tribe.lifecycle_reason && (
              <KV label="Lifecycle reason" value={tribe.lifecycle_reason} />
            )}
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

        <div className="lg:col-span-2 flex flex-col gap-6">
          <Card
            title={`Members · ${tribe.member_count}`}
            hint="Latest 250 · every change needs a reason and is audited"
            padded={false}
          >
            {canManage && <div className="grid gap-4 border-b border-line px-5 py-4 md:grid-cols-2">
              <WorkflowForm action={addTribeMember} blockUncertainRetry label="Add member" confirmation="Adds this member to the tribe straight away, without a join request.">
                <input type="hidden" name="tribe_id" value={tribeId} />
                <label className="contact-field"><span>Member (handle or user ID)</span><input name="member" className="input" required maxLength={60} placeholder="@handle" /></label>
                <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. invited by the keeper" /></label>
              </WorkflowForm>
              <WorkflowForm action={removeTribeMember} blockUncertainRetry label="Remove member" confirmation="Removes this member from the tribe. They can ask to join again unless the tribe is private.">
                <input type="hidden" name="tribe_id" value={tribeId} />
                <label className="contact-field"><span>Member (handle or user ID)</span><input name="member" className="input" required maxLength={60} placeholder="@handle" /></label>
                <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. repeated harassment in the tribe" /></label>
              </WorkflowForm>
            </div>}
            {((members ?? []) as unknown[]).length === 0 ? (
              <div className="px-5 py-8 text-sm text-ink-muted italic">
                No members.
              </div>
            ) : (
              <ul className="divide-y divide-line max-h-[420px] overflow-auto">
                {((members ?? []) as unknown as {
                  user_id: string;
                  role: string;
                  users: { anonymous_pseudonym: string } | null;
                }[]).map((m) => (
                  <li
                    key={m.user_id}
                    className="px-5 py-2.5 flex items-center gap-3"
                  >
                    <Link
                      href={`/users/${m.user_id}`}
                      className="text-sm font-semibold text-burgundy hover:text-berry flex-1 min-w-0 truncate"
                    >
                      @{m.users?.anonymous_pseudonym ?? "—"}
                    </Link>
                    <Badge tone={m.role === "keeper" ? "info" : "neutral"}>
                      {m.role}
                    </Badge>
                  </li>
                ))}
              </ul>
            )}
          </Card>

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
                    <Link href={`/content/${p.post_id}`} className="block text-sm text-burgundy line-clamp-3 hover:underline">
                      {p.content || "Media only"}
                    </Link>
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
