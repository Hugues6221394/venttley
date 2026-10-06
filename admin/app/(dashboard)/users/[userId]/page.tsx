import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import {
  createAdminClient,
  createRequiredAuthAdminClient,
  createSsrClient,
} from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { limitAction } from "@/lib/guard";
import { enumOf, optStr, uuid } from "@/lib/validate";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { Tabs } from "@/components/ui/tabs";
import { MemberContact, type ContactChannel, type ContactOptions } from "@/components/member-contact";
import {
  CheckCircle2,
  ChevronLeft,
  KeyRound,
  Mail,
  OctagonAlert,
  Send,
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
] as const;

// Only what users_account_status_check actually permits. The dropdown used to
// offer "banned" and "shadow_banned"; neither is a valid account_status, so
// both failed at the database every time. A permanent ban is 'suspended' with
// suspended_until NULL (see 0085_moderation_power_tools.sql); shadow
// restriction is a separate boolean, set from /moderation.
const STATUSES = ["active", "suspended", "restricted"] as const;

/**
 * Turn a thrown error into something the page can say out loud.
 *
 * Next redacts server error messages before they reach the browser, so an
 * action that throws surfaces as "Minified React error #441" plus a digest and
 * nothing else — which is what an operator saw when they tried to demote an
 * account, and again when they tried to rename one. The message existed the
 * whole time; it just never left the server. Actions now finish by redirecting
 * with a code this page knows how to render, the same pattern /staff uses.
 */
function resultCode(error: unknown): string {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  if (message.includes("self_change")) return "self_change";
  if (message.includes("caller is not staff")) return "self_change";
  if (message.includes("mfa") || message.includes("aal2")) return "mfa_required";
  if (message.includes("forbidden") || message.includes("not_authorized")) {
    return "forbidden";
  }
  if (message.includes("username_changes_disabled")) return "handle_permanent";
  if (message.includes("rate limit")) return "rate_limited";
  if (message.includes("must be") || message.includes("is required")) {
    return "invalid_input";
  }
  return "failed";
}

function finish(userId: string, code: string): never {
  revalidatePath(`/users/${userId}`);
  redirect(`/users/${userId}?result=${encodeURIComponent(code)}`);
}

/**
 * Who is making this request.
 *
 * Needed because a super admin acting on their own account is a special case
 * the database cannot express cleanly: admin_set_user_role updates the row and
 * *then* calls admin_log, which re-checks is_staff(auth.uid()). Demote
 * yourself and the audit write fails as "caller is not staff", rolling the
 * whole thing back — so the action silently does nothing and reports an opaque
 * digest. /staff already refuses self-changes outright for this reason; this
 * page simply never learned the rule.
 */
async function currentActorId(): Promise<string | null> {
  const supabase = await createSsrClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return user?.id ?? null;
}

const NOTICE: Record<string, { tone: "ok" | "warn" | "danger"; text: string }> = {
  status_changed: { tone: "ok", text: "Account status changed. The member's sessions were revoked." },
  role_changed: { tone: "ok", text: "Role changed. The member's sessions were revoked." },
  profile_updated: { tone: "ok", text: "Profile updated." },
  verified_changed: { tone: "ok", text: "Verified badge updated." },
  self_change: {
    tone: "danger",
    text:
      "You cannot change your own role or status here. Removing your own staff access mid-action makes the audit write fail, so the whole change is rolled back. Sign in as another super admin and do it from there.",
  },
  handle_permanent: { tone: "warn", text: "Handles are permanent and cannot be changed after the account exists." },
  mfa_required: { tone: "warn", text: "Complete the MFA challenge before making this change." },
  forbidden: { tone: "danger", text: "Only an active super admin can perform this action." },
  rate_limited: { tone: "warn", text: "Too many changes in a short window. Wait a moment and try again." },
  invalid_input: { tone: "danger", text: "Check the submitted values and try again." },
  failed: { tone: "danger", text: "The change did not go through, and nothing was altered. Check the audit log before retrying." },
};

async function setStatus(formData: FormData) {
  "use server";
  const id = uuid(formData, "user_id");
  let code = "status_changed";
  try {
    await limitAction("destructive");
    // Suspending yourself has the same failure as demoting yourself: staff
    // authorization requires an active account, so admin_log stops recognising
    // the caller mid-transaction.
    if ((await currentActorId()) === id) throw new Error("self_change");
    await rpc("admin_set_user_status", {
      p_target: id,
      p_status: enumOf(formData, "status", STATUSES),
      p_reason: optStr(formData, "reason", 500),
    });
  } catch (error) {
    code = resultCode(error);
  }
  finish(id, code);
}

async function setRole(formData: FormData) {
  "use server";
  const id = uuid(formData, "user_id");
  let code = "role_changed";
  try {
    await limitAction("destructive");
    if ((await currentActorId()) === id) throw new Error("self_change");
    await rpc("admin_set_user_role", {
      p_target: id,
      p_role: enumOf(formData, "role", ROLES),
      p_reason: optStr(formData, "reason", 500),
    });
  } catch (error) {
    code = resultCode(error);
  }
  finish(id, code);
}

async function editProfile(formData: FormData) {
  "use server";
  const id = uuid(formData, "user_id");
  let code = "profile_updated";
  try {
  const verified = String(formData.get("is_verified") ?? "");
  await rpc("admin_update_user_profile", {
    p_target: id,
    p_pseudonym: optStr(formData, "pseudonym", 100),
    p_is_verified: verified === "" ? null : verified === "true",
    p_safety_tier: optStr(formData, "safety_tier", 50),
    p_home_city: optStr(formData, "home_city", 100),
    p_home_country: optStr(formData, "home_country", 100),
    p_reason: optStr(formData, "reason", 500),
  });
  } catch (error) {
    code = resultCode(error);
  }
  finish(id, code);
}

async function setVerified(formData: FormData) {
  "use server";
  const id = uuid(formData, "user_id");
  let code = "verified_changed";
  try {
    const v = enumOf(formData, "verified", ["true", "false", "clear"] as const);
    await rpc("admin_set_user_verified", {
      p_target: id,
      p_verified: v === "clear" ? null : v === "true",
      p_reason: optStr(formData, "reason", 500),
    });
  } catch (error) {
    code = resultCode(error);
  }
  finish(id, code);
}

async function resetPassword(formData: FormData) {
  "use server";
  await limitAction("destructive");
  const id = uuid(formData, "user_id");
  const pw = String(formData.get("password") ?? "");
  const reason = optStr(formData, "reason", 500);
  // Lower bound matches admin_authorize_password_reset's own check; the upper
  // bound is here because bcrypt hashes whatever it is given.
  if (pw.length < 12 || pw.length > 200) {
    throw new Error("Password must be between 12 and 200 characters.");
  }

  // Checks is_staff(super_admin), AAL2, and the recovery-phrase guard in the
  // database. GoTrue owns auth.users' password hash, so the actual mutation
  // stays on the Auth Admin API below rather than a direct SQL UPDATE.
  await rpc("admin_authorize_password_reset", { p_target: id });

  const authAdmin = createRequiredAuthAdminClient();
  const { error } = await authAdmin.auth.admin.updateUserById(id, {
    password: pw,
  });
  if (error) throw new Error(`Password reset failed: ${error.message}`);

  // Audits and revokes the target's existing sessions now that the reset has
  // actually happened. This can't be transactionally atomic with the Auth
  // Admin API call above — that's a different system over the network — so
  // this runs as the very next statement rather than claiming atomicity SQL
  // can't deliver across that boundary.
  await rpc("admin_finalize_password_reset", {
    p_target: id,
    p_reason: reason,
  });
  revalidatePath(`/users/${id}`);
}

async function deleteUser(formData: FormData) {
  "use server";
  await limitAction("destructive");
  const id = uuid(formData, "user_id");
  const confirm = String(formData.get("confirm") ?? "");
  if (confirm !== "DELETE") {
    // Guard against accidental submits — require typing DELETE.
    revalidatePath(`/users/${id}`);
    return;
  }
  await rpc("admin_delete_user", {
    p_target: id,
    p_reason: optStr(formData, "reason", 500),
  });
  redirect("/users");
}

const TABS = ["overview", "communications", "account", "security"] as const;
type MemberTab = (typeof TABS)[number];

type Communication = {
  communication_id: string;
  channel: "message" | "warning" | "email";
  subject: string;
  body: string;
  policy_code: string | null;
  appealable: boolean | null;
  actor_pseudonym: string | null;
  actor_role: string;
  email_hint: string | null;
  delivery_status: string;
  rescinded_at: string | null;
  created_at: string;
};

const CHANNEL_LABEL: Record<Communication["channel"], string> = {
  message: "In-app message",
  warning: "Formal warning",
  email: "Email",
};

const DELIVERY_LABEL: Record<string, string> = {
  delivered: "Delivered",
  read: "Read",
  removed_by_member: "Dismissed by member",
  queued: "Queued",
  sending: "Sending",
  sent: "Sent",
  failed: "Failed",
  skipped: "Not deliverable",
  unknown: "",
};

export default async function UserDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ userId: string }>;
  searchParams: Promise<{ result?: string; tab?: string; compose?: string }>;
}) {
  const { userId } = await params;
  const { result, tab: rawTab, compose } = await searchParams;
  const tab: MemberTab = (TABS as readonly string[]).includes(rawTab ?? "") ? (rawTab as MemberTab) : "overview";
  const notice = result ? NOTICE[result] ?? NOTICE.failed : null;
  const db = await createAdminClient();
  const session = await createSsrClient();

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
    { data: contactData },
    { data: communicationsData },
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
        (
          await db.from("posts").select("post_id").eq("author_id", userId)
        ).data?.map((p) => p.post_id) ?? []
      ),
    db
      .from("tribe_members")
      .select("tribe_id", { count: "exact", head: true })
      .eq("user_id", userId),
    db
      .from("posts")
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
      .limit(20),
    // Both self-gate on the operator's role; a role that cannot contact
    // members gets an error and the composer explains why.
    session.rpc("admin_member_contact_options", { p_member: userId }),
    session.rpc("admin_member_communications", { p_member: userId, p_limit: 50 }),
  ]);

  const contact = contactData as ContactOptions | null;
  const communications = (communicationsData ?? []) as Communication[];
  const warnings = communications.filter((c) => c.channel === "warning" && !c.rescinded_at).length;
  const lastContact = communications[0]?.created_at ?? null;
  const initialChannel: ContactChannel =
    compose === "warning" || compose === "email" ? compose : "message";

  const { data: sessionsData } =
    tab === "security"
      ? await session.rpc("admin_user_sessions", { p_target: userId })
      : { data: null };
  const sessions = (sessionsData ?? []) as {
    session_id: string;
    ip: string | null;
    user_agent: string | null;
    aal: string | null;
    created_at: string;
    updated_at: string;
    not_after: string | null;
  }[];

  const handle = `@${user.anonymous_pseudonym}`;
  const base = `/users/${user.user_id}`;
  const composeHref = (channel: ContactChannel) => `${base}?tab=communications&compose=${channel}#contact`;
  const statusTone =
    user.account_status === "active" ? "ok" : user.account_status === "suspended" ? "danger" : "warn";

  return (
    <div className="member-profile">
      {notice && (
        <div className={`member-notice is-${notice.tone}`} role="status">
          <p>{notice.text}</p>
        </div>
      )}

      <Link href="/users" className="member-back">
        <ChevronLeft size={14} /> All members
      </Link>

      <header className="member-header">
        <div className="member-identity">
          <div className="member-avatar" aria-hidden="true">
            {user.anonymous_pseudonym.slice(0, 2).toUpperCase()}
          </div>
          <div className="min-w-0">
            <h1>{handle}</h1>
            <div className="member-meta">
              <Badge tone={statusTone}>
                {user.account_status}
              </Badge>
              <span>{user.user_role.replaceAll("_", " ")}</span>
              {user.is_verified && (
                <span className="inline-flex items-center gap-1">
                  <CheckCircle2 size={12} /> Verified
                </span>
              )}
              <span>Joined {new Date(user.created_at).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })}</span>
              <span className="font-mono select-all member-id" title="Member ID">
                {user.user_id.slice(0, 8)}
              </span>
            </div>
          </div>
        </div>
        <div className="member-actions">
          {contact && !contact.is_self && (
            <>
              <Link href={composeHref("message")} className="btn-primary">
                <Send size={15} /> Message
              </Link>
              {contact.can_warn && (
                <Link href={composeHref("warning")} className="btn-secondary">
                  <OctagonAlert size={15} /> Warn
                </Link>
              )}
              {contact.email_available ? (
                <Link href={composeHref("email")} className="btn-secondary" title={`Email ${contact.email_hint}`}>
                  <Mail size={15} /> Email
                </Link>
              ) : (
                <button type="button" className="btn-secondary" disabled title="No verified email address on this account">
                  <Mail size={15} /> Email
                </button>
              )}
            </>
          )}
          <Link href={`${base}?tab=account`} className="btn-ghost">
            <ShieldAlert size={15} /> Account actions
          </Link>
        </div>
      </header>

      <section className="operator-metrics member-metrics" aria-label="Member summary">
        {(
          [
            ["Live posts", postCount ?? 0, null],
            ["Comments", commentCount ?? 0, null],
            ["Reports against", reportsAgainst ?? 0, (reportsAgainst ?? 0) > 0 ? "is-alert" : null],
            ["Active warnings", warnings, warnings > 0 ? "is-alert" : null],
            ["Tribes", tribeCount ?? 0, null],
          ] as const
        ).map(([label, value, tone]) => (
          <div key={label} className={`operator-metric ${tone ?? ""}`}>
            <h3>{label}</h3>
            <div className="operator-metric-value">
              <strong className={value === 0 ? "is-zero" : ""}>{value.toLocaleString()}</strong>
            </div>
          </div>
        ))}
      </section>

      <Tabs
        basePath={base}
        active={tab}
        tabs={[
          { key: "overview", label: "Overview" },
          { key: "communications", label: "Communications", count: communications.length || undefined },
          { key: "account", label: "Account" },
          { key: "security", label: "Security & audit" },
        ]}
      />

      {tab === "overview" && (
        <div className="member-grid">
          <Card title="Recent posts" hint="Last 8 posts. Open one to see its reports and cases." padded={false}>
            {(recentPosts ?? []).length === 0 ? (
              <p className="member-empty">No posts yet.</p>
            ) : (
              <ul className="member-list">
                {(recentPosts ?? []).map(
                  (p: {
                    post_id: string;
                    content: string;
                    created_at: string;
                    likes_count: number;
                    comments_count: number;
                    crisis_level: string | null;
                  }) => (
                    <li key={p.post_id}>
                      <div className="member-list-head">
                        {p.crisis_level && <Badge tone="crisis">crisis · {p.crisis_level}</Badge>}
                        <time>{new Date(p.created_at).toLocaleString()}</time>
                      </div>
                      <Link href={`/content/${p.post_id}`} className="member-list-body line-clamp-2 block hover:text-burgundy">{p.content || "Media only"}</Link>
                      <p className="member-list-foot tabular">
                        {p.likes_count} hugs · {p.comments_count} comments
                      </p>
                    </li>
                  )
                )}
              </ul>
            )}
          </Card>

          <div className="member-side">
            <Card title="Profile" padded>
              <KV label="Karma" value={user.karma_points.toLocaleString()} />
              <KV label="Mood" value={user.current_mood ?? "—"} />
              <KV label="Safety tier" value={user.safety_tier} />
              <KV
                label="Location"
                value={[user.home_city, user.home_campus, user.home_country].filter(Boolean).join(", ") || "—"}
              />
              <KV label="Last contacted" value={lastContact ? new Date(lastContact).toLocaleDateString() : "Never"} />
            </Card>
            {Array.isArray(badges) && badges.length > 0 && (
              <Card title="Badges" padded>
                <div className="flex flex-wrap gap-1.5">
                  {badges.map((b: { badge_key: string }) => (
                    <Badge key={b.badge_key} tone="neutral">
                      {b.badge_key.replaceAll("_", " ")}
                    </Badge>
                  ))}
                </div>
              </Card>
            )}
            {Array.isArray(streaks) && streaks.length > 0 && (
              <Card title="Streaks" padded>
                {(streaks as { streak_kind: string; current_count: number; longest_count: number }[]).map((s) => (
                  <KV key={s.streak_kind} label={s.streak_kind} value={`${s.current_count} now · ${s.longest_count} best`} />
                ))}
              </Card>
            )}
          </div>
        </div>
      )}

      {tab === "communications" && (
        <div className="member-grid">
          <Card title="History" hint="Everything staff have sent this member. Kept even if the member dismisses it." padded={false}>
            {communications.length === 0 ? (
              <p className="member-empty">Nobody has contacted this member from the console yet.</p>
            ) : (
              <ol className="member-list">
                {communications.map((c) => (
                  <li key={c.communication_id} className={c.rescinded_at ? "is-rescinded" : undefined}>
                    <div className="member-list-head">
                      <span className={`contact-channel is-${c.channel}`}>{CHANNEL_LABEL[c.channel]}</span>
                      <span className="contact-status">
                        {c.rescinded_at ? "Rescinded on appeal" : DELIVERY_LABEL[c.delivery_status] ?? c.delivery_status}
                      </span>
                      <time>{new Date(c.created_at).toLocaleString()}</time>
                    </div>
                    <p className="member-list-title">
                      {c.subject}
                      {c.policy_code && <span className="contact-policy">{c.policy_code}</span>}
                    </p>
                    <p className="member-list-body whitespace-pre-wrap">{c.body}</p>
                    <p className="member-list-foot">
                      By @{c.actor_pseudonym ?? "former staff"} · {c.actor_role.replaceAll("_", " ")}
                      {c.email_hint && <> · to {c.email_hint}</>}
                      {c.channel === "warning" && <> · {c.appealable ? "appealable" : "not appealable"}</>}
                    </p>
                  </li>
                ))}
              </ol>
            )}
          </Card>
          <div className="member-side" id="contact">
            <Card title="Contact this member" hint="Requires MFA. Every send is audit-logged.">
              {contact ? (
                <MemberContact memberId={user.user_id} handle={handle} options={contact} initial={initialChannel} />
              ) : (
                <p className="operator-note">Your role can view this member but cannot contact them.</p>
              )}
            </Card>
          </div>
        </div>
      )}

      {tab === "account" && (
        <div className="member-account">
          <Card title="Status and access" hint="Status changes notify the member and revoke their sessions.">
            <div className="member-forms">
              <form action={setStatus} className="member-form">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="member-form-label">Account status</label>
                <div className="member-form-row">
                  <select name="status" className="select" defaultValue={user.account_status}>
                    {STATUSES.map((s) => (
                      <option key={s} value={s}>{s}</option>
                    ))}
                  </select>
                  <input type="text" name="reason" placeholder="Reason, shown to the member" className="input" />
                  <button type="submit" className="btn-secondary">Apply</button>
                </div>
              </form>

              <form action={setRole} className="member-form">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="member-form-label"><KeyRound size={12} /> Role <small>super admin only</small></label>
                <div className="member-form-row">
                  <select name="role" className="select" defaultValue={user.user_role}>
                    {ROLES.map((r) => (
                      <option key={r} value={r}>{r.replaceAll("_", " ")}</option>
                    ))}
                  </select>
                  <input type="text" name="reason" placeholder="Reason" className="input" />
                  <button type="submit" className="btn-secondary">Assign</button>
                </div>
              </form>

              <form action={setVerified} className="member-form">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="member-form-label">
                  <CheckCircle2 size={12} /> Verified badge <small>currently {user.is_verified ? "on" : "off"}</small>
                </label>
                <div className="member-form-row">
                  <input type="text" name="reason" placeholder="Reason" className="input" />
                  <button type="submit" name="verified" value="true" className="btn-secondary">Verify</button>
                  <button type="submit" name="verified" value="false" className="btn-secondary">Unverify</button>
                  <button type="submit" name="verified" value="clear" className="btn-ghost" title="Let the automatic milestone system decide.">Auto</button>
                </div>
              </form>

              <form action={resetPassword} className="member-form">
                <input type="hidden" name="user_id" value={user.user_id} />
                <label className="member-form-label"><KeyRound size={12} /> Reset password <small>super admin only</small></label>
                <p className="member-form-hint">Phrase-protected accounts must use their recovery phrase; an admin reset cannot safely reseal it.</p>
                <div className="member-form-row">
                  <input type="text" name="password" placeholder="New password, 12+ characters" minLength={12} required className="input" autoComplete="off" />
                  <input type="text" name="reason" placeholder="Reason" className="input" />
                  <button type="submit" className="btn-secondary">Set</button>
                </div>
              </form>
            </div>
          </Card>

          <Card title="Public profile" hint="Overwrites the member's public fields. Audited.">
            <form action={editProfile} className="member-form-grid">
              <input type="hidden" name="user_id" value={user.user_id} />
              {/* Handles are permanent: users_identity_guard refuses any change. */}
              <label className="member-field">
                <span>Handle</span>
                <input type="text" value={handle} className="input" readOnly disabled />
              </label>
              <label className="member-field">
                <span>Verified</span>
                <select name="is_verified" className="select" defaultValue="">
                  <option value="">No change</option>
                  <option value="true">Verified</option>
                  <option value="false">Unverified</option>
                </select>
              </label>
              <label className="member-field">
                <span>Safety tier</span>
                <input type="text" name="safety_tier" defaultValue={user.safety_tier} className="input" />
              </label>
              <label className="member-field">
                <span>City</span>
                <input type="text" name="home_city" defaultValue={user.home_city ?? ""} className="input" />
              </label>
              <label className="member-field">
                <span>Country</span>
                <input type="text" name="home_country" defaultValue={user.home_country ?? ""} className="input" />
              </label>
              <label className="member-field">
                <span>Reason</span>
                <input type="text" name="reason" placeholder="Optional" className="input" />
              </label>
              <div className="member-form-submit">
                <button type="submit" className="btn-secondary">Save profile</button>
              </div>
            </form>
          </Card>

          <Card title="Delete account" hint="Permanent. Deletes the login and all of the member's content." className="member-danger">
            <form action={deleteUser} className="member-form-row">
              <input type="hidden" name="user_id" value={user.user_id} />
              <input type="text" name="reason" placeholder="Reason" className="input" />
              <input type="text" name="confirm" placeholder="Type DELETE to confirm" className="input" autoComplete="off" />
              <button type="submit" className="btn-danger">
                <Trash2 size={15} /> Delete account
              </button>
            </form>
          </Card>
        </div>
      )}

      {tab === "security" && (
        <div className="member-grid">
          <Card title="Admin timeline" hint="Audit entries for this member." padded={false}>
            {(timeline ?? []).length === 0 ? (
              <p className="member-empty">No admin actions on this member yet.</p>
            ) : (
              <ol className="member-list">
                {(timeline ?? []).map(
                  (t: { audit_id: string; action: string; actor_pseudonym: string; reason: string | null; created_at: string }) => (
                    <li key={t.audit_id}>
                      <div className="member-list-head">
                        <Badge tone={timelineTone(t.action)}>{t.action}</Badge>
                        <time>{new Date(t.created_at).toLocaleString()}</time>
                      </div>
                      {t.reason && <p className="member-list-body">“{t.reason}”</p>}
                      <p className="member-list-foot">By @{t.actor_pseudonym}</p>
                    </li>
                  )
                )}
              </ol>
            )}
          </Card>
          <div className="member-side">
            <Card title="Sessions" hint="Active sessions with device and IP. Super admin only." padded={false}>
              {sessions.length === 0 ? (
                <p className="member-empty">No active sessions, or your role cannot view them.</p>
              ) : (
                <ul className="member-list">
                  {sessions.map((s) => (
                    <li key={s.session_id}>
                      <div className="member-list-head">
                        <span className="font-mono select-all">{s.ip ?? "—"}</span>
                        {s.aal && <Badge tone="neutral">{s.aal}</Badge>}
                        <time>{new Date(s.updated_at).toLocaleString()}</time>
                      </div>
                      <p className="member-list-foot truncate">{s.user_agent ?? "Unknown device"}</p>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          </div>
        </div>
      )}
    </div>
  );
}

function timelineTone(action: string): "ok" | "warn" | "danger" | "info" | "neutral" {
  if (action.includes("delete") || action.includes("ban") || action.includes("suspend"))
    return "danger";
  if (action.includes("warning")) return "warn";
  if (action.includes("restore") || action.includes("reactivate") || action === "user.set_status")
    return "info";
  if (action.includes("role")) return "info";
  return "neutral";
}
