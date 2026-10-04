import Link from "next/link";
import { randomUUID } from "node:crypto";
import { notFound } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { reconcileBounded } from "@/lib/bounded";
import { activeSuperAdminQuery, directoryFilters, directoryRoles, STAFF_PAGE_SIZE, staffDirectoryQuery } from "@/lib/staff-directory-model";
import { StaffDirectoryFilters, StaffDirectoryPages } from "@/components/staff-directory-controls";
import { WorkflowForm } from "@/components/workflows/workflow-form";
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

const STAFF_ROLES = directoryRoles;

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

export default async function StaffPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const ssr = await createSsrClient();
  const {
    data: { user: actor },
  } = await ssr.auth.getUser();
  if (!actor) notFound();
  const role = await activeStaffRole(ssr, actor.id, ["super_admin"]);
  if (role !== "super_admin") notFound();

  const filters = directoryFilters(params);
  if (!filters) return <div><ErrorPanel title="Invalid staff filters" detail="Choose a supported role and account state, or restart the directory." /><Link href="/staff" className="btn-secondary">Reset staff filters</Link></div>;

  const db = await createAdminClient();
  const [staffResult, protectionResult] = await Promise.all([
    staffDirectoryQuery(db, filters), activeSuperAdminQuery(db),
  ]);
  const staff = (staffResult.error ? [] : (staffResult.data ?? []).slice(0, STAFF_PAGE_SIZE)) as Staff[];
  const hasMore = !staffResult.error && (staffResult.data?.length ?? 0) > STAFF_PAGE_SIZE;
  const nextId = hasMore ? staff.at(-1)?.user_id : undefined;

  let authAvailable = true;
  let authError: string | null = null;
  const authById = new Map<string, AuthSummary>();
  try {
    createRequiredAuthAdminClient(); // Credential readiness; no network request.
    let authAdmin: ReturnType<typeof createRequiredAuthAdminClient> | undefined;
    // Resolve only the visible page, never the lookahead row or tenant users.
    const authRows = await reconcileBounded(
      staff,
      5,
      6_000,
      async (member, signal) => ({
        id: member.user_id,
        result: await (authAdmin ??= createRequiredAuthAdminClient(signal)).auth.admin.getUserById(member.user_id),
      }),
    );
    for (const lookup of authRows) {
      if (lookup.status !== "fulfilled") {
        authError = "Some Auth checks failed or exceeded the shared time budget. Their state is unknown; refresh to retry.";
        continue;
      }
      const row = lookup.value;
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

  const activeSuperAdmins = protectionResult.error ? null : protectionResult.data?.length ?? null;
  const inviteRedirectConfigured = !!process.env.ADMIN_INVITE_REDIRECT_URL?.trim();
  const invitationsPaused = process.env.ADMIN_STAFF_INVITES_DISABLED === "true";

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

      {staffResult.error && (
        <ErrorPanel
          title="Staff directory could not be loaded"
          detail="Refresh to retry. No empty or healthy directory is inferred from this failure."
        />
      )}
      {activeSuperAdmins === null && <ErrorPanel title="Super-admin safety count is unavailable" detail="Removal of super-admin access is disabled here until this check succeeds. The database still independently protects the last active super admin." />}
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
          {invitationsPaused && <p role="status" className="mb-3 text-sm text-ink-muted">New staff invitations are paused by the deployment owner. Existing records and access controls remain available.</p>}
          <WorkflowForm action={inviteStaff} label="Send staff invitation" disabled={invitationsPaused || !authAvailable || !inviteRedirectConfigured} blockUncertainRetry confirmation="Verify the mailbox, permanent handle and initial role. This requests an Auth invitation and grants staff access; email delivery is not guaranteed. Inspect partial results before retrying.">
            <input type="hidden" name="operation_id" value={randomUUID()} />
            <div>
              <label htmlFor="staff-invite-email" className="h-eyebrow mb-1 block">Work email</label>
              <input
                id="staff-invite-email"
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
              <label htmlFor="staff-invite-handle" className="h-eyebrow mb-1 block">Handle</label>
              <input
                id="staff-invite-handle"
                name="pseudonym"
                required
                minLength={3}
                maxLength={24}
                pattern="[A-Za-z0-9_]+"
                autoComplete="off"
                className="input w-full"
                placeholder="venttly_admin"
                disabled={!authAvailable || !inviteRedirectConfigured}
              />
              <p className="mt-1 text-[11px] text-ink-muted">
                Permanent — it cannot be changed after the invitation is sent,
                and every audit entry this person writes will carry it. Name the
                role, not the person.
              </p>
            </div>
            <div>
              <label htmlFor="staff-invite-role" className="h-eyebrow mb-1 block">Initial role</label>
              <select
                id="staff-invite-role"
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
              <label htmlFor="staff-invite-reason" className="h-eyebrow mb-1 block">Business reason</label>
              <input
                id="staff-invite-reason"
                name="reason"
                required
                maxLength={500}
                className="input w-full"
                placeholder="Role, team, approver, and expected duties"
                disabled={!authAvailable || !inviteRedirectConfigured}
              />
            </div>
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
          </WorkflowForm>
        </Card>

        <Card
          title="Grant access to an existing account"
          hint="Recovery path for an existing invite or a pre-created member"
        >
          <WorkflowForm action={grantExistingStaff} label="Grant access" blockUncertainRetry confirmation="Verify this account and the requested role. The audited operation grants staff authority and may revoke existing sessions.">
            <div>
              <label htmlFor="staff-grant-id" className="h-eyebrow mb-1 block">Immutable user ID</label>
              <input
                id="staff-grant-id"
                name="user_id"
                required
                className="input w-full font-mono text-xs"
                placeholder="00000000-0000-0000-0000-000000000000"
              />
            </div>
            <div>
              <label htmlFor="staff-grant-role" className="h-eyebrow mb-1 block">Role</label>
              <select id="staff-grant-role" name="role" className="select w-full" defaultValue="moderator">
                {STAFF_ROLES.map((value) => (
                  <option key={value} value={value}>
                    {value.replaceAll("_", " ")}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="staff-grant-reason" className="h-eyebrow mb-1 block">Business reason</label>
              <input
                id="staff-grant-reason"
                name="reason"
                required
                maxLength={500}
                className="input w-full"
                placeholder="Why this account needs staff access"
              />
            </div>
          </WorkflowForm>
        </Card>
      </div>

      <Card
        title="Current staff"
        hint={`${staffResult.error ? "Unknown number of" : staff.length} accounts on this page · ${activeSuperAdmins === null ? "unknown" : activeSuperAdmins === 2 ? "2+" : activeSuperAdmins} active super admins across the directory`}
        padded={false}
      >
        <StaffDirectoryFilters filters={filters} path="/staff" />
        {staffResult.error ? null : staff.length === 0 ? (
          <EmptyState
            icon={<UserRoundCog size={34} />}
            title="No staff accounts on this page."
            hint="Change filters or return to the first page. Staff membership may have changed while you were browsing."
          />
        ) : (
          <ul className="divide-y divide-line">
            {staff.map((member) => {
              const auth = authById.get(member.user_id);
              const isSelf = member.user_id === actor.id;
              const isLastSuperAdmin =
                member.user_role === "super_admin" && (activeSuperAdmins === null || activeSuperAdmins <= 1);
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
                          tone={member.account_status === "active" && !member.deactivated_at ? "ok" : "warn"}
                        >
                          {member.deactivated_at ? "deactivated" : member.account_status}
                        </Badge>
                        {isSelf && <Badge>you</Badge>}
                        {auth && !auth.confirmed && <Badge tone="warn">invite pending</Badge>}
                      </div>
                      <p className="mt-1 text-xs text-ink-muted">
                        {auth?.email ?? "mailbox hidden/unavailable"}
                        {!auth ? " · sign-in history unknown" : auth.lastSignIn
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
                        <WorkflowForm action={changeStaffRole} label="Save role" blockUncertainRetry confirmation="Change this account's staff role and revoke its existing sessions. Verify the account and business reason before confirming.">
                          <input type="hidden" name="user_id" value={member.user_id} />
                          <label htmlFor={`staff-role-${member.user_id}`} className="h-eyebrow">Change role</label>
                          <select id={`staff-role-${member.user_id}`} name="role" className="select" defaultValue={member.user_role}>
                            {STAFF_ROLES.map((value) => (
                              <option key={value} value={value}>
                                {value.replaceAll("_", " ")}
                              </option>
                            ))}
                          </select>
                          <label>Business reason<input name="reason" required maxLength={500} className="input" placeholder="Required reason" /></label>
                        </WorkflowForm>

                        <WorkflowForm action={setStaffStatus} label="Apply status" blockUncertainRetry confirmation="Change this account's access status and revoke its existing sessions. This affects the member account as well as staff access.">
                          <input type="hidden" name="user_id" value={member.user_id} />
                          <label htmlFor={`staff-status-${member.user_id}`} className="h-eyebrow">Account access</label>
                          <select id={`staff-status-${member.user_id}`} name="status" className="select" defaultValue={member.account_status === "active" ? "suspended" : "active"}>
                            <option value="active">active</option>
                            <option value="suspended">suspended</option>
                          </select>
                          <label>Business reason<input name="reason" required maxLength={500} className="input" placeholder="Required reason" /></label>
                        </WorkflowForm>

                        <WorkflowForm action={removeStaffAccess} label="Remove from staff" disabled={isLastSuperAdmin} blockUncertainRetry confirmation="Remove staff authority and revoke sessions. This does not erase the member account, authored content or audit history.">
                          <input type="hidden" name="user_id" value={member.user_id} />
                          <label>Business reason<input name="reason" required maxLength={500} className="input" placeholder="Required reason" /></label>
                          <label>Removal confirmation<input name="confirm" required maxLength={20} className="input" placeholder="Type REMOVE" /></label>
                          {isLastSuperAdmin && <p className="text-[11px] text-danger">{activeSuperAdmins === null ? "Super-admin safety count is unknown. Refresh before removing access." : "The last active super admin is protected."}</p>}
                        </WorkflowForm>
                      </div>
                    )}
                  </details>
                </li>
              );
            })}
          </ul>
        )}
        <StaffDirectoryPages filters={filters} nextId={nextId} path="/staff" />
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
