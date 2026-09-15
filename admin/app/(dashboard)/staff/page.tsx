import Link from "next/link";
import { notFound } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { mapBounded } from "@/lib/bounded";
import {
  createAdminClient,
  createRequiredAuthAdminClient,
  createSsrClient,
} from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { KeyRound, UserRoundCog } from "@/components/ui/icons";
import {
  changeStaffRole,
  grantExistingStaff,
  inviteStaff,
  removeStaffAccess,
  setStaffStatus,
} from "./actions";

export const dynamic = "force-dynamic";

const STAFF_ROLES = [
  "super_admin",
  "admin",
  "moderator",
  "support",
  "analyst",
  "read_only_auditor",
] as const;

const INVITABLE_STAFF_ROLES = STAFF_ROLES.filter(
  (role) => role !== "super_admin",
);

type Staff = {
  user_id: string;
  display_name: string;
  anonymous_pseudonym: string;
  user_role: (typeof STAFF_ROLES)[number];
  account_status: string;
  deactivated_at: string | null;
  created_at: string;
  last_seen_at: string | null;
};

type AuthSummary = {
  email: string | null;
  confirmed: boolean;
  lastSignIn: string | null;
};

const NOTICE: Record<string, { tone: "ok" | "warn" | "danger"; text: string }> = {
  invited: { tone: "ok", text: "Invitation sent and staff access assigned." },
  access_granted: { tone: "ok", text: "Staff access granted to the existing account." },
  role_changed: { tone: "ok", text: "Staff role changed and existing sessions revoked." },
  status_changed: { tone: "ok", text: "Staff account status changed and existing sessions revoked." },
  access_removed: { tone: "ok", text: "Staff access removed. The member account and audit history were preserved." },
  mfa_required: { tone: "warn", text: "Complete the MFA challenge before changing staff access." },
  forbidden: { tone: "danger", text: "Only an active super admin can perform this action." },
  already_exists: { tone: "warn", text: "That mailbox already has an Auth account. Use its immutable user ID to grant access, or inspect the existing account." },
  last_super_admin: { tone: "danger", text: "The last active super admin cannot be demoted or removed." },
  self_change: { tone: "danger", text: "You cannot change or remove your own access from this page." },
  invalid_input: { tone: "danger", text: "Check the submitted email, ID, role, confirmation, and reason." },
  failed: { tone: "danger", text: "The staff operation did not complete. Review the audit log before retrying so an ambiguous network response is not mistaken for failure." },
};

export default async function StaffPage({
  searchParams,
}: {
  searchParams: Promise<{ result?: string }>;
}) {
  const { result } = await searchParams;
  const ssr = await createSsrClient();
  const {
    data: { user: actor },
  } = await ssr.auth.getUser();
  if (!actor) notFound();
  const role = await activeStaffRole(ssr, actor.id, ["super_admin"]);
  if (role !== "super_admin") notFound();

  const db = await createAdminClient();
  const staffResult = await db
    .from("users")
    .select(
      "user_id, display_name, anonymous_pseudonym, user_role, account_status, deactivated_at, created_at, last_seen_at",
    )
    .in("user_role", STAFF_ROLES)
    .order("user_role")
    .order("created_at");
  const staff = (staffResult.data ?? []) as Staff[];

  let authAvailable = true;
  let authError: string | null = null;
  const authById = new Map<string, AuthSummary>();
  try {
    const authAdmin = createRequiredAuthAdminClient();
    // Staff is intentionally a small set. Resolve only those immutable IDs
    // rather than listing the first N Auth users, which stops working as soon
    // as the social tenant grows beyond that arbitrary page.
    const authRows = await mapBounded(
      staff,
      10,
      async (member) => ({
        id: member.user_id,
        result: await authAdmin.auth.admin.getUserById(member.user_id),
      }),
    );
    for (const row of authRows) {
      if (row.result.error || !row.result.data.user) {
        authError = "One or more staff Auth records could not be resolved.";
        continue;
      }
      const authUser = row.result.data.user;
      authById.set(row.id, {
        email: authUser.email ?? null,
        confirmed: !!authUser.email_confirmed_at,
        lastSignIn: authUser.last_sign_in_at ?? null,
      });
    }
  } catch (error) {
    authAvailable = false;
    authError =
      error instanceof Error
        ? error.message
        : "Auth Admin directory unavailable.";
  }

  const activeSuperAdmins = staff.filter(
    (member) =>
      member.user_role === "super_admin" &&
      member.account_status === "active" &&
      !member.deactivated_at,
  ).length;
  const notice = result ? NOTICE[result] : null;
  const inviteRedirectConfigured = !!process.env.ADMIN_INVITE_REDIRECT_URL?.trim();

  return (
    <div className="flex max-w-[1250px] flex-col gap-6">
      <PageHeader
        eyebrow="Manage"
        title="Staff accounts"
        subtitle="Invite administrators, change least-privilege roles, suspend access, or remove staff authority without erasing member data or the audit trail. Every access mutation requires AAL2 and is database-audited."
        actions={
          <div className="flex gap-2">
            <Link href="/staff/invitations" className="btn-secondary">Invitation ledger</Link>
            <Link href="/roles" className="btn-secondary">Permission matrix</Link>
          </div>
        }
      />

      {notice && (
        <div className="surface-flat flex items-center gap-2 px-4 py-3">
          <Badge tone={notice.tone}>{notice.tone === "ok" ? "complete" : "attention"}</Badge>
          <p className="text-sm text-burgundy">{notice.text}</p>
        </div>
      )}

      {staffResult.error && (
        <ErrorPanel
          title="Staff directory could not be loaded"
          detail={staffResult.error.message}
        />
      )}
      {authError && (
        <ErrorPanel
          title={
            authAvailable
              ? "Some staff mailbox status is unavailable"
              : "Auth invitation and mailbox status are unavailable"
          }
          detail={authError}
          hint={
            authAvailable
              ? "Role and account state remain authoritative; only the missing Auth details are shown as unavailable."
              : "Public staff roles are still shown, but invitations remain disabled until the server-only Auth Admin credential is configured."
          }
        />
      )}

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card
          title="Invite a new staff member"
          hint="Creates a real-mailbox Auth account, then grants an audited role"
        >
          <form action={inviteStaff} className="flex flex-col gap-3">
            <div>
              <label className="h-eyebrow mb-1 block">Work email</label>
              <input
                type="email"
                name="email"
                required
                maxLength={320}
                autoComplete="off"
                className="input w-full"
                placeholder="moderator@company.com"
                disabled={!authAvailable || !inviteRedirectConfigured}
              />
            </div>
            <div>
              <label className="h-eyebrow mb-1 block">Initial role</label>
              <select
                name="role"
                className="select w-full"
                defaultValue="moderator"
                disabled={!authAvailable || !inviteRedirectConfigured}
              >
                {INVITABLE_STAFF_ROLES.map((value) => (
                  <option key={value} value={value}>
                    {value.replaceAll("_", " ")}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="h-eyebrow mb-1 block">Business reason</label>
              <input
                name="reason"
                required
                maxLength={500}
                className="input w-full"
                placeholder="Role, team, approver, and expected duties"
                disabled={!authAvailable || !inviteRedirectConfigured}
              />
            </div>
            <button
              type="submit"
              className="btn-primary"
              disabled={!authAvailable || !inviteRedirectConfigured}
            >
              Send staff invitation
            </button>
            {!inviteRedirectConfigured && (
              <p className="text-xs text-danger">
                Configure ADMIN_INVITE_REDIRECT_URL before invitations can be
                sent.
              </p>
            )}
            <p className="text-[11px] text-ink-muted">
              Super-admin access is never granted in the email invitation.
              Promote an accepted, MFA-capable staff account separately.
            </p>
          </form>
        </Card>

        <Card
          title="Grant access to an existing account"
          hint="Recovery path for an existing invite or a pre-created member"
        >
          <form action={grantExistingStaff} className="flex flex-col gap-3">
            <div>
              <label className="h-eyebrow mb-1 block">Immutable user ID</label>
              <input
                name="user_id"
                required
                className="input w-full font-mono text-xs"
                placeholder="00000000-0000-0000-0000-000000000000"
              />
            </div>
            <div>
              <label className="h-eyebrow mb-1 block">Role</label>
              <select name="role" className="select w-full" defaultValue="moderator">
                {STAFF_ROLES.map((value) => (
                  <option key={value} value={value}>
                    {value.replaceAll("_", " ")}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="h-eyebrow mb-1 block">Business reason</label>
              <input
                name="reason"
                required
                maxLength={500}
                className="input w-full"
                placeholder="Why this account needs staff access"
              />
            </div>
            <button type="submit" className="btn-secondary">
              Grant access
            </button>
          </form>
        </Card>
      </div>

      <Card
        title="Current staff"
        hint={`${staff.length} accounts · ${activeSuperAdmins} active super admin${activeSuperAdmins === 1 ? "" : "s"}`}
        padded={false}
      >
        {staff.length === 0 ? (
          <EmptyState
            icon={<UserRoundCog size={34} />}
            title="No staff accounts returned."
            hint="If this page is visible, the directory query is likely degraded."
          />
        ) : (
          <ul className="divide-y divide-line">
            {staff.map((member) => {
              const auth = authById.get(member.user_id);
              const isSelf = member.user_id === actor.id;
              const isLastSuperAdmin =
                member.user_role === "super_admin" && activeSuperAdmins <= 1;
              return (
                <li key={member.user_id} className="px-5 py-5">
                  <div className="flex flex-wrap items-start gap-3">
                    <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-berry text-sm font-extrabold text-white">
                      {(member.display_name || member.anonymous_pseudonym)
                        .slice(0, 2)
                        .toUpperCase()}
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <Link
                          href={`/users/${member.user_id}`}
                          className="font-bold text-burgundy hover:text-berry"
                        >
                          {member.display_name}
                        </Link>
                        <span className="text-xs text-ink-muted">
                          @{member.anonymous_pseudonym}
                        </span>
                        <Badge
                          tone={member.user_role === "super_admin" ? "danger" : "info"}
                        >
                          {member.user_role.replaceAll("_", " ")}
                        </Badge>
                        <Badge
                          tone={member.account_status === "active" ? "ok" : "warn"}
                        >
                          {member.account_status}
                        </Badge>
                        {isSelf && <Badge>you</Badge>}
                        {auth && !auth.confirmed && <Badge tone="warn">invite pending</Badge>}
                      </div>
                      <p className="mt-1 text-xs text-ink-muted">
                        {auth?.email ?? "mailbox hidden/unavailable"}
                        {auth?.lastSignIn
                          ? ` · last sign-in ${new Date(auth.lastSignIn).toLocaleString()}`
                          : " · never signed in"}
                      </p>
                      <p className="mt-1 select-all font-mono text-[10px] text-ink-muted">
                        {member.user_id}
                      </p>
                    </div>
                  </div>

                  <details className="mt-4 border-t border-line pt-3">
                    <summary className="cursor-pointer text-xs font-bold text-berry">
                      Edit or remove access
                    </summary>
                    {isSelf ? (
                      <p className="mt-3 text-xs text-ink-muted">
                        Self-service role, suspension, and removal are blocked to
                        prevent accidental lockout. Another super admin must make
                        the change.
                      </p>
                    ) : (
                      <div className="mt-3 grid grid-cols-1 gap-4 xl:grid-cols-3">
                        <form action={changeStaffRole} className="surface-flat flex flex-col gap-2 p-3">
                          <input type="hidden" name="user_id" value={member.user_id} />
                          <label className="h-eyebrow">Change role</label>
                          <select name="role" className="select" defaultValue={member.user_role}>
                            {STAFF_ROLES.map((value) => (
                              <option key={value} value={value}>
                                {value.replaceAll("_", " ")}
                              </option>
                            ))}
                          </select>
                          <input name="reason" required maxLength={500} className="input" placeholder="Required reason" />
                          <button type="submit" className="btn-secondary">Save role</button>
                        </form>

                        <form action={setStaffStatus} className="surface-flat flex flex-col gap-2 p-3">
                          <input type="hidden" name="user_id" value={member.user_id} />
                          <label className="h-eyebrow">Account access</label>
                          <select name="status" className="select" defaultValue={member.account_status === "active" ? "suspended" : "active"}>
                            <option value="active">active</option>
                            <option value="suspended">suspended</option>
                          </select>
                          <input name="reason" required maxLength={500} className="input" placeholder="Required reason" />
                          <button type="submit" className="btn-secondary">Apply status</button>
                        </form>

                        <form action={removeStaffAccess} className="surface-flat flex flex-col gap-2 border-danger/20 bg-danger/5 p-3">
                          <input type="hidden" name="user_id" value={member.user_id} />
                          <label className="h-eyebrow text-danger">Remove staff access</label>
                          <input name="reason" required maxLength={500} className="input" placeholder="Required reason" />
                          <input name="confirm" required maxLength={20} className="input" placeholder="Type REMOVE" />
                          <button type="submit" className="btn-secondary text-danger" disabled={isLastSuperAdmin}>
                            Remove from staff
                          </button>
                          {isLastSuperAdmin && <p className="text-[11px] text-danger">The only active super admin cannot be removed.</p>}
                        </form>
                      </div>
                    )}
                  </details>
                </li>
              );
            })}
          </ul>
        )}
      </Card>

      <CapabilityNotice title="Removing staff access is intentionally not account erasure">
        “Remove from staff” changes the role to normal and revokes sessions via
        the audited database RPC. It preserves authored content and the actor
        identity required by the append-only audit trail. Permanent Auth/account
        deletion is a separate privacy operation and must not be disguised as
        staff cleanup.
      </CapabilityNotice>

      <Card title="Invite readiness" hint="Required before sending a real invitation">
        <ul className="space-y-2 text-xs text-ink-muted">
          <li className="flex items-center gap-2"><KeyRound size={13} /> Auth Admin service credential: <Badge tone={authAvailable ? "ok" : "danger"}>{authAvailable ? "available" : "missing"}</Badge></li>
          <li className="flex items-center gap-2"><KeyRound size={13} /> Invite redirect URL: <Badge tone={inviteRedirectConfigured ? "ok" : "danger"}>{inviteRedirectConfigured ? "configured" : "missing"}</Badge></li>
          <li>Supabase&rsquo;s Invite user email template must use <code className="font-mono">&#123;&#123; .RedirectTo &#125;&#125;/auth/confirm?token_hash=&#123;&#123; .TokenHash &#125;&#125;&amp;type=invite</code>, and the admin origin must be in Auth&rsquo;s allowed redirect URLs.</li>
          <li>Production custom SMTP is required; Supabase&rsquo;s default sender is not a production delivery service.</li>
        </ul>
      </Card>
    </div>
  );
}
