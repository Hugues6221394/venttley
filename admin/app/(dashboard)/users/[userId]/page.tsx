import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import {
  Ban,
  CheckCircle2,
  ChevronLeft,
  EyeOff,
  KeyRound,
  ShieldAlert,
  Trash2,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const ROLES = [
  "normal",
  "plug",
  "moderator",
  "support",
  "analyst",
  "admin",
  "super_admin",
  "read_only_auditor",
];

async function setStatus(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const status = String(formData.get("status") ?? "");
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_set_user_status", {
    p_target: id,
    p_status: status,
    p_reason: reason || null,
  });
  revalidatePath(`/users/${id}`);
}

async function setRole(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const role = String(formData.get("role") ?? "");
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_set_user_role", {
    p_target: id,
    p_role: role,
    p_reason: reason || null,
  });
  revalidatePath(`/users/${id}`);
}

async function editProfile(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const verified = String(formData.get("is_verified") ?? "");
  await rpc("admin_update_user_profile", {
    p_target: id,
    p_pseudonym: (String(formData.get("pseudonym") ?? "").trim()) || null,
    p_is_verified: verified === "" ? null : verified === "true",
    p_safety_tier: (String(formData.get("safety_tier") ?? "").trim()) || null,
    p_home_city: (String(formData.get("home_city") ?? "").trim()) || null,
    p_home_country: (String(formData.get("home_country") ?? "").trim()) || null,
    p_reason: (String(formData.get("reason") ?? "").trim()) || null,
  });
  revalidatePath(`/users/${id}`);
}

async function setVerified(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const v = String(formData.get("verified") ?? "");
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_set_user_verified", {
    p_target: id,
    p_verified: v === "clear" ? null : v === "true",
    p_reason: reason || null,
  });
  revalidatePath(`/users/${id}`);
}

async function resetPassword(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const pw = String(formData.get("password") ?? "");
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_reset_user_password", {
    p_target: id,
    p_new_password: pw,
    p_reason: reason || null,
  });
  revalidatePath(`/users/${id}`);
}

async function deleteUser(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const confirm = String(formData.get("confirm") ?? "");
  if (confirm !== "DELETE") {
    // Guard against accidental submits — require typing DELETE.
    revalidatePath(`/users/${id}`);
    return;
  }
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_delete_user", { p_target: id, p_reason: reason || null });
  redirect("/users");
}

export default async function UserDetailPage({
  params,
}: {
  params: Promise<{ userId: string }>;
}) {
  const { userId } = await params;
  const db = await createAdminClient();

  const { data: user } = await db
    .from("users")
    .select(
      "user_id, anonymous_pseudonym, avatar_seed, user_role, safety_tier, account_status, karma_points, current_mood, is_verified, home_country, home_city, home_campus, created_at"
    )
    .eq("user_id", userId)
    .maybeSingle();

  if (!user) notFound();

  const [
    { count: postCount },
    { count: commentCount },
    { count: reportsAgainst },
    { count: tribeCount },
    { data: recentPosts },
    { data: badges },
    { data: streaks },
    { data: timeline },
  ] = await Promise.all([
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .eq("author_id", userId)
      .is("deleted_at", null),
    db
      .from("posts_comments")
      .select("comment_id", { count: "exact", head: true })
      .eq("author_id", userId),
    db
      .from("reports")
      .select("report_id", { count: "exact", head: true })
      .in(
        "post_id",
        // posts authored by this user
        (
          await db.from("posts").select("post_id").eq("author_id", userId)
        ).data?.map((p) => p.post_id) ?? []
      ),
    db
      .from("tribe_members")
      .select("tribe_id", { count: "exact", head: true })
      .eq("user_id", userId),
    db
      .from("feed_posts")
      .select("post_id, content, created_at, likes_count, comments_count, crisis_level")
      .eq("author_id", userId)
      .order("created_at", { ascending: false })
      .limit(8),
    db
      .from("user_badges")
      .select("badge_key, awarded_at")
      .eq("user_id", userId)
      .order("awarded_at", { ascending: false })
      .limit(8),
    db
      .from("user_streaks")
      .select("streak_kind, current_count, longest_count, last_event_at")
      .eq("user_id", userId),
    db
      .from("audit_log")
      .select("audit_id, action, actor_pseudonym, reason, created_at, target_label")
      .eq("target_type", "user")
      .eq("target_id", userId)
      .order("created_at", { ascending: false })
      .limit(12),
  ]);

  // Sessions + IPs — super_admin only (the RPC self-gates; non-super_admins
  // get an error and an empty list).
  const { data: sessionsData } = await db.rpc("admin_user_sessions", {
    p_target: userId,
  });
  const sessions = (sessionsData ?? []) as {
    session_id: string;
    ip: string | null;
    user_agent: string | null;
    aal: string | null;
    created_at: string;
    updated_at: string;
    not_after: string | null;
  }[];

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <div>
        <Link href="/users" className="btn-ghost mb-3">
          <ChevronLeft size={14} /> Users
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-4">
            <div className="h-14 w-14 rounded-2xl bg-berry text-white flex items-center justify-center text-xl font-extrabold shadow-soft">
              {user.anonymous_pseudonym.slice(0, 2).toUpperCase()}
            </div>
            <div>
              <h1 className="h-page">@{user.anonymous_pseudonym}</h1>
              <div className="flex flex-wrap items-center gap-2 mt-1.5">
                <Badge tone={user.user_role === "super_admin" ? "danger" : user.user_role === "admin" || user.user_role === "moderator" ? "info" : "neutral"}>
                  {user.user_role}
                </Badge>
                <Badge
                  tone={
                    user.account_status === "active"
                      ? "ok"
                      : user.account_status === "suspended"
                        ? "warn"
                        : "danger"
                  }
                  icon={user.account_status === "shadow_banned" ? <EyeOff size={11} /> : undefined}
                >
                  {user.account_status}
                </Badge>
                <span className="text-xs text-ink-muted">
                  joined {new Date(user.created_at).toLocaleDateString()}
                </span>
              </div>
            </div>
          </div>
          <div className="text-right">
            <p className="h-eyebrow">User ID</p>
            <p className="font-mono text-xs text-ink-muted select-all">
              {user.user_id}
            </p>
          </div>
        </div>
      </div>

      {/* Metrics strip */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Card padded>
          <p className="h-eyebrow mb-1">Live posts</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">{postCount ?? 0}</p>
        </Card>
        <Card padded>
          <p className="h-eyebrow mb-1">Comments</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">{commentCount ?? 0}</p>
        </Card>
        <Card padded>
          <p className="h-eyebrow mb-1">Reports against</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">{reportsAgainst ?? 0}</p>
        </Card>
        <Card padded>
          <p className="h-eyebrow mb-1">Tribes joined</p>
          <p className="tabular text-2xl font-extrabold text-burgundy">{tribeCount ?? 0}</p>
        </Card>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* LEFT: actions + facts */}
        <div className="flex flex-col gap-6">
          <Card title="Account actions" hint="Every action is audit-logged.">
            <div className="flex flex-col gap-4">
              <form action={setStatus} className="flex flex-col gap-2">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="h-eyebrow">Account status</label>
                <div className="flex gap-2">
                  <select name="status" className="select flex-1" defaultValue={user.account_status}>
                    <option value="active">active</option>
                    <option value="suspended">suspended</option>
                    <option value="banned">banned</option>
                    <option value="shadow_banned">shadow_banned</option>
                  </select>
                  <input
                    type="text"
                    name="reason"
                    placeholder="reason"
                    className="input flex-1"
                  />
                  <button type="submit" className="btn-secondary">
                    Apply
                  </button>
                </div>
              </form>

              <form action={setRole} className="flex flex-col gap-2">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="h-eyebrow flex items-center gap-1">
                  <KeyRound size={11} /> Role (super_admin only)
                </label>
                <div className="flex gap-2">
                  <select name="role" className="select flex-1" defaultValue={user.user_role}>
                    {ROLES.map((r) => (
                      <option key={r} value={r}>
                        {r}
                      </option>
                    ))}
                  </select>
                  <input
                    type="text"
                    name="reason"
                    placeholder="reason"
                    className="input flex-1"
                  />
                  <button type="submit" className="btn-secondary">
                    Assign
                  </button>
                </div>
              </form>

              <form action={resetPassword} className="flex flex-col gap-2">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="h-eyebrow flex items-center gap-1">
                  <KeyRound size={11} /> Reset password (super_admin only)
                </label>
                <div className="flex gap-2">
                  <input
                    type="text"
                    name="password"
                    placeholder="new password (8+ chars)"
                    minLength={8}
                    required
                    className="input flex-1"
                    autoComplete="off"
                  />
                  <input
                    type="text"
                    name="reason"
                    placeholder="reason"
                    className="input flex-1"
                  />
                  <button type="submit" className="btn-secondary">
                    Set
                  </button>
                </div>
              </form>

              <form action={setVerified} className="flex flex-col gap-2">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="h-eyebrow flex items-center gap-1">
                  <CheckCircle2 size={11} /> Verified badge — currently{" "}
                  {user.is_verified ? "ON" : "OFF"} (super_admin)
                </label>
                <input
                  type="text"
                  name="reason"
                  placeholder="reason"
                  className="input"
                />
                <div className="flex gap-2">
                  <button
                    type="submit"
                    name="verified"
                    value="true"
                    className="btn-secondary flex-1"
                  >
                    Verify
                  </button>
                  <button
                    type="submit"
                    name="verified"
                    value="false"
                    className="btn-secondary flex-1"
                  >
                    Unverify
                  </button>
                  <button
                    type="submit"
                    name="verified"
                    value="clear"
                    className="btn-ghost flex-1"
                    title="Clear the manual override — let the automatic milestone system decide."
                  >
                    Auto
                  </button>
                </div>
              </form>
            </div>
          </Card>

          <Card title="Edit profile" hint="Overwrites the user's public fields. Audited.">
            <form action={editProfile} className="flex flex-col gap-3">
              <input type="hidden" name="user_id" value={user.user_id} />
              <div className="flex flex-col gap-1">
                <label className="h-eyebrow">Pseudonym</label>
                <input
                  type="text"
                  name="pseudonym"
                  defaultValue={user.anonymous_pseudonym}
                  className="input"
                />
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
                  <label className="h-eyebrow">Verified</label>
                  <select name="is_verified" className="select" defaultValue="">
                    <option value="">no change</option>
                    <option value="true">verified</option>
                    <option value="false">unverified</option>
                  </select>
                </div>
                <div className="flex flex-col gap-1">
                  <label className="h-eyebrow">Safety tier</label>
                  <input
                    type="text"
                    name="safety_tier"
                    defaultValue={user.safety_tier}
                    className="input"
                  />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
                  <label className="h-eyebrow">City</label>
                  <input
                    type="text"
                    name="home_city"
                    defaultValue={user.home_city ?? ""}
                    className="input"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <label className="h-eyebrow">Country</label>
                  <input
                    type="text"
                    name="home_country"
                    defaultValue={user.home_country ?? ""}
                    className="input"
                  />
                </div>
              </div>
              <input
                type="text"
                name="reason"
                placeholder="reason (optional)"
                className="input"
              />
              <button type="submit" className="btn-secondary self-start">
                Save profile
              </button>
            </form>
          </Card>

          <Card title="Danger zone" hint="Permanent. Deletes the login + all their content.">
            <form action={deleteUser} className="flex flex-col gap-2">
              <input type="hidden" name="user_id" value={user.user_id} />
              <input
                type="text"
                name="reason"
                placeholder="reason"
                className="input"
              />
              <div className="flex gap-2">
                <input
                  type="text"
                  name="confirm"
                  placeholder="type DELETE to confirm"
                  className="input flex-1"
                  autoComplete="off"
                />
                <button
                  type="submit"
                  className="btn-secondary text-red-600 border-red-300 hover:bg-red-50 inline-flex items-center gap-1"
                >
                  <Trash2 size={13} /> Delete user
                </button>
              </div>
            </form>
          </Card>

          <Card title="Profile facts" padded>
            <KV label="Pseudonym" value={`@${user.anonymous_pseudonym}`} />
            <KV label="Karma" value={user.karma_points.toLocaleString()} />
            <KV label="Mood" value={user.current_mood ?? "—"} />
            <KV label="Verified" value={user.is_verified ? "yes" : "no"} />
            <KV label="Safety tier" value={user.safety_tier} />
            <KV
              label="Location"
              value={
                [user.home_city, user.home_campus, user.home_country]
                  .filter(Boolean)
                  .join(", ") || "—"
              }
            />
          </Card>

          {Array.isArray(badges) && badges.length > 0 && (
            <Card title="Badges" padded>
              <div className="flex flex-wrap gap-1.5">
                {badges.map((b: { badge_key: string }) => (
                  <Badge key={b.badge_key} tone="info">
                    {b.badge_key}
                  </Badge>
                ))}
              </div>
            </Card>
          )}

          {Array.isArray(streaks) && streaks.length > 0 && (
            <Card title="Streaks" padded>
              {(streaks as { streak_kind: string; current_count: number; longest_count: number }[]).map((s) => (
                <KV
                  key={s.streak_kind}
                  label={s.streak_kind}
                  value={`${s.current_count} cur · ${s.longest_count} best`}
                />
              ))}
            </Card>
          )}
        </div>

        {/* RIGHT: timeline + recent posts */}
        <div className="lg:col-span-2 flex flex-col gap-6">
          <Card
            title="Recent posts"
            hint="Last 8 live posts by this user. Tap → /moderation for action."
            padded={false}
          >
            {(recentPosts ?? []).length === 0 ? (
              <div className="px-5 py-10 text-sm text-ink-muted italic">
                No posts yet.
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {(recentPosts ?? []).map(
                  (p: {
                    post_id: string;
                    content: string;
                    created_at: string;
                    likes_count: number;
                    comments_count: number;
                    crisis_level: string | null;
                  }) => (
                    <li key={p.post_id} className="px-5 py-3">
                      <div className="flex items-center gap-2 mb-1">
                        {p.crisis_level && (
                          <Badge tone="crisis">crisis · {p.crisis_level}</Badge>
                        )}
                        <p className="text-[11px] text-ink-muted ml-auto">
                          {new Date(p.created_at).toLocaleString()}
                        </p>
                      </div>
                      <p className="text-sm text-burgundy line-clamp-2">
                        {p.content}
                      </p>
                      <p className="text-[11px] text-ink-muted mt-1">
                        ♡ {p.likes_count} · 💬 {p.comments_count}
                      </p>
                    </li>
                  )
                )}
              </ul>
            )}
          </Card>

          <Card
            title="Admin timeline"
            hint="Audit entries scoped to this user — bans, role changes, status flips."
            padded={false}
          >
            {(timeline ?? []).length === 0 ? (
              <div className="px-5 py-10 text-sm text-ink-muted italic">
                No admin actions taken on this user yet.
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {(timeline ?? []).map(
                  (t: {
                    audit_id: string;
                    action: string;
                    actor_pseudonym: string;
                    reason: string | null;
                    created_at: string;
                  }) => (
                    <li
                      key={t.audit_id}
                      className="px-5 py-3 flex items-start gap-3"
                    >
                      <Badge tone={timelineTone(t.action)}>{t.action}</Badge>
                      <div className="flex-1 min-w-0">
                        <p className="text-xs text-burgundy">
                          by{" "}
                          <span className="font-semibold">
                            @{t.actor_pseudonym}
                          </span>
                        </p>
                        {t.reason && (
                          <p className="text-xs text-ink-muted italic">
                            “{t.reason}”
                          </p>
                        )}
                      </div>
                      <p className="text-[11px] text-ink-muted whitespace-nowrap">
                        {new Date(t.created_at).toLocaleString()}
                      </p>
                    </li>
                  )
                )}
              </ul>
            )}
          </Card>

          <Card
            title="Sessions & IP addresses"
            hint="Active GoTrue sessions with device + IP. super_admin only."
            padded={false}
          >
            {sessions.length === 0 ? (
              <div className="px-5 py-8 text-sm text-ink-muted italic">
                No active sessions (or you lack super_admin to view them).
              </div>
            ) : (
              <ul className="divide-y divide-line">
                {sessions.map((s) => (
                  <li key={s.session_id} className="px-5 py-3 flex items-start gap-3">
                    <div className="flex-1 min-w-0">
                      <p className="font-mono text-sm text-burgundy select-all">
                        {s.ip ?? "—"}
                      </p>
                      <p className="text-[11px] text-ink-muted truncate">
                        {s.user_agent ?? "unknown device"}
                      </p>
                    </div>
                    {s.aal && <Badge tone="neutral">{s.aal}</Badge>}
                    <p className="text-[11px] text-ink-muted whitespace-nowrap">
                      {new Date(s.updated_at).toLocaleString()}
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

function timelineTone(action: string): "ok" | "warn" | "danger" | "info" | "neutral" {
  if (action.includes("delete") || action.includes("ban") || action.includes("suspend"))
    return "danger";
  if (action.includes("restore") || action.includes("reactivate") || action === "user.set_status")
    return "info";
  if (action.includes("role")) return "info";
  return "neutral";
}
