import Link from "next/link";
import { notFound } from "next/navigation";
import { createAdminClient } from "@/lib/supabase/server";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { ChevronLeft, Send, ShieldAlert } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Post = {
  post_id: string; author_id: string; tribe_id: string | null; content: string | null; post_type: string | null;
  post_mood: string | null; likes_count: number; comments_count: number; view_count: number | null;
  created_at: string; edited_at: string | null; deleted_at: string | null; hidden_at: string | null;
  sensitive_at: string | null; archived_at: string | null; locked_at: string | null; media_status: string | null;
  crisis_level: string | null; is_story: boolean; is_whisper: boolean; persona_id: string | null;
  image_url: string | null; audio_url: string | null;
};
type Report = { report_id: string; reason: string; note: string | null; created_at: string; is_resolved: boolean; case_id: string | null; target_comment_id: string | null };
type Case = { case_id: string; status: string; severity: string; decision: string | null; policy_code: string | null; report_count: number; opened_at: string; decided_at: string | null };
type Comment = { comment_id: string; author_id: string; content: string | null; created_at: string; deleted_at: string | null; likes_count: number };
type Person = { user_id: string; anonymous_pseudonym: string; display_name: string | null; account_status: string };

function postState(p: Post): { label: string; tone: Tone } {
  if (p.deleted_at) return { label: "removed", tone: "danger" };
  if (p.hidden_at) return { label: "hidden", tone: "warn" };
  if (p.media_status && !["clean", "approved"].includes(p.media_status)) return { label: `media ${p.media_status}`, tone: "warn" };
  if (p.archived_at) return { label: "archived", tone: "neutral" };
  return { label: "live", tone: "ok" };
}

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : "—");

export default async function PostPage({ params }: { params: Promise<{ postId: string }> }) {
  const { postId } = await params;
  if (!UUID.test(postId)) notFound();
  const db = await createAdminClient();

  const { data: post } = await db
    .from("posts")
    .select("post_id, author_id, tribe_id, content, post_type, post_mood, likes_count, comments_count, view_count, created_at, edited_at, deleted_at, hidden_at, sensitive_at, archived_at, locked_at, media_status, crisis_level, is_story, is_whisper, persona_id, image_url, audio_url")
    .eq("post_id", postId)
    .maybeSingle<Post>();
  if (!post) notFound();

  const [reportsRes, casesRes, commentsRes, tribeRes] = await Promise.all([
    db.from("reports").select("report_id, reason, note, created_at, is_resolved, case_id, target_comment_id")
      .eq("post_id", postId).order("created_at", { ascending: false }).limit(50),
    db.from("moderation_cases").select("case_id, status, severity, decision, policy_code, report_count, opened_at, decided_at")
      .eq("target_type", "post").eq("target_id", postId).order("opened_at", { ascending: false }).limit(20),
    db.from("posts_comments").select("comment_id, author_id, content, created_at, deleted_at, likes_count")
      .eq("post_id", postId).order("created_at", { ascending: false }).limit(20),
    post.tribe_id ? db.from("tribes").select("tribe_id, name").eq("tribe_id", post.tribe_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const reports = (reportsRes.data ?? []) as Report[];
  const cases = (casesRes.data ?? []) as Case[];
  const comments = (commentsRes.data ?? []) as Comment[];
  const tribe = tribeRes.data as { tribe_id: string; name: string } | null;

  const peopleIds = [...new Set([post.author_id, ...comments.map(c => c.author_id)])];
  const { data: peopleRows } = await db.from("users")
    .select("user_id, anonymous_pseudonym, display_name, account_status").in("user_id", peopleIds);
  const people = new Map(((peopleRows ?? []) as Person[]).map(p => [p.user_id, p]));
  const author = people.get(post.author_id);

  const state = postState(post);
  const openReports = reports.filter(r => !r.is_resolved).length;
  const openCase = cases.find(c => c.status !== "resolved");
  const kind = post.is_story ? "Story" : post.is_whisper ? "Whisper" : "Vent";

  return (
    <div className="member-profile">
      <Link href="/content" className="member-back"><ChevronLeft size={14} /> Content explorer</Link>

      <header className="member-header">
        <div className="member-identity">
          <div>
            <h1>{kind} by {author ? `@${author.anonymous_pseudonym}` : "unknown member"}</h1>
            <div className="member-meta">
              <Badge tone={state.tone}>{state.label}</Badge>
              {post.crisis_level && <Badge tone="crisis">crisis · {post.crisis_level}</Badge>}
              {post.persona_id && <span>Posted behind a persona</span>}
              {tribe && <span>in <Link href={`/tribes/${tribe.tribe_id}`} className="text-burgundy hover:underline">{tribe.name}</Link></span>}
              <span>{new Date(post.created_at).toLocaleDateString()}</span>
              <span className="member-id">{post.post_id.slice(0, 8)}</span>
            </div>
          </div>
        </div>
        <div className="member-actions">
          {openCase && (
            <Link href={`/moderation/cases/${openCase.case_id}`} className="btn-primary">
              <ShieldAlert size={15} /> Open case
            </Link>
          )}
          {author && (
            <Link href={`/users/${author.user_id}?tab=communications&compose=message#contact`} className="btn-secondary">
              <Send size={15} /> Message author
            </Link>
          )}
          {author && <Link href={`/users/${author.user_id}`} className="btn-ghost">Author profile</Link>}
        </div>
      </header>

      <section className="operator-metrics member-metrics" aria-label="Post summary">
        {([
          ["Hugs", post.likes_count, false],
          ["Comments", post.comments_count, false],
          ["Views", post.view_count ?? 0, false],
          ["Open reports", openReports, openReports > 0],
          ["Cases", cases.length, !!openCase],
        ] as const).map(([label, value, alert]) => (
          <div key={label} className={`operator-metric${alert ? " is-alert" : ""}`}>
            <h3>{label}</h3>
            <div className="operator-metric-value"><strong className={value === 0 ? "is-zero" : ""}>{value.toLocaleString()}</strong></div>
          </div>
        ))}
      </section>

      <div className="member-grid">
        <div className="member-side">
          <Card title="Content" hint={post.edited_at ? `Edited ${when(post.edited_at)}` : undefined} padded>
            <p className="post-body">{post.content || "No text. This item contains media only."}</p>
            {(post.image_url || post.audio_url) && (
              <p className="member-list-foot">
                {post.image_url && "Has an image. "}{post.audio_url && "Has a voice note. "}Media is reviewed in Media safety.
              </p>
            )}
          </Card>

          <Card title="Reports" hint={`${reports.length} total · ${openReports} open`} padded={false}>
            {reports.length === 0 ? <p className="member-empty">No one has reported this.</p> : (
              <ul className="member-list">
                {reports.map(r => (
                  <li key={r.report_id}>
                    <div className="member-list-head">
                      <span className="contact-channel">{r.reason.replaceAll("_", " ")}</span>
                      {r.target_comment_id && <span className="contact-status">about a comment</span>}
                      <span className="contact-status">{r.is_resolved ? "resolved" : "open"}</span>
                      <time>{when(r.created_at)}</time>
                    </div>
                    {r.note && <p className="member-list-body">{r.note}</p>}
                    {r.case_id && <p className="member-list-foot"><Link href={`/moderation/cases/${r.case_id}`} className="text-burgundy hover:underline">Linked case</Link></p>}
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Recent comments" hint={`Latest ${comments.length}`} padded={false}>
            {comments.length === 0 ? <p className="member-empty">No comments.</p> : (
              <ul className="member-list">
                {comments.map(c => {
                  const who = people.get(c.author_id);
                  return (
                    <li key={c.comment_id} className={c.deleted_at ? "is-rescinded" : undefined}>
                      <div className="member-list-head">
                        <Link href={`/users/${c.author_id}`} className="member-list-title text-burgundy hover:underline" style={{ marginTop: 0 }}>
                          @{who?.anonymous_pseudonym ?? "unknown"}
                        </Link>
                        {c.deleted_at && <span className="contact-status">removed</span>}
                        <time>{when(c.created_at)}</time>
                      </div>
                      <p className="member-list-body">{c.content || "Media only"}</p>
                    </li>
                  );
                })}
              </ul>
            )}
          </Card>
        </div>

        <div className="member-side">
          <Card title="Moderation" hint="Removal and restrictions are decided in a case, with a reason and an appeal path." padded={false}>
            {cases.length === 0 ? <p className="member-empty">No case has been opened for this post.</p> : (
              <ul className="member-list">
                {cases.map(c => (
                  <li key={c.case_id}>
                    <div className="member-list-head">
                      <Badge tone={c.status === "resolved" ? "neutral" : "warn"}>{c.status.replaceAll("_", " ")}</Badge>
                      <span className="contact-status">{c.severity}</span>
                      <time>{when(c.opened_at)}</time>
                    </div>
                    <p className="member-list-title">
                      {c.decision ? c.decision.replaceAll("_", " ") : `${c.report_count} ${c.report_count === 1 ? "report" : "reports"}, undecided`}
                      {c.policy_code && <span className="contact-policy">{c.policy_code}</span>}
                    </p>
                    <p className="member-list-foot"><Link href={`/moderation/cases/${c.case_id}`} className="text-burgundy hover:underline">Open case</Link></p>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Details">
            <KV label="Type" value={`${kind}${post.post_type ? ` · ${post.post_type}` : ""}`} />
            <KV label="Mood" value={post.post_mood ?? "—"} />
            <KV label="Author status" value={author?.account_status ?? "—"} />
            <KV label="Created" value={when(post.created_at)} />
            {post.deleted_at && <KV label="Removed" value={when(post.deleted_at)} />}
            {post.hidden_at && <KV label="Hidden" value={when(post.hidden_at)} />}
            {post.sensitive_at && <KV label="Marked sensitive" value={when(post.sensitive_at)} />}
            {post.locked_at && <KV label="Comments locked" value={when(post.locked_at)} />}
            <KV label="Post ID" value={<span className="font-mono text-[11px] select-all">{post.post_id}</span>} />
          </Card>
        </div>
      </div>
    </div>
  );
}
