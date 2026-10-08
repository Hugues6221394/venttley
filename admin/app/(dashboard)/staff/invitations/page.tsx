import Link from "next/link";
import { notFound } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { reconcileBounded } from "@/lib/bounded";
import { directoryFilters, directoryRoles, STAFF_PAGE_SIZE, staffDirectoryQuery } from "@/lib/staff-directory-model";
import { StaffDirectoryFilters, StaffDirectoryPages } from "@/components/staff-directory-controls";
import { createAdminClient, createRequiredAuthAdminClient, createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { KeyRound } from "@/components/ui/icons";
import { invitationCursor } from "@/lib/staff-invitation-model";
import { StaffInvitationRegister } from "@/components/workflows/staff-invitation-register";
import { WorkflowForm } from "@/components/workflows/workflow-form";
import { resendStaffInvite, revokeStaffInvite } from "../actions";

export const dynamic = "force-dynamic";

const STAFF_ROLES = directoryRoles;

type StaffRow = {
  user_id: string;
  display_name: string;
  anonymous_pseudonym: string;
  user_role: (typeof STAFF_ROLES)[number];
  account_status: string;
  created_at: string;
};

type InviteRow = StaffRow & {
  email: string | null;
  emailConfirmed: boolean;
  pendingFlag: boolean;
  lastSignIn: string | null;
  authCreatedAt: string;
};

function maskEmail(email: string | null): string {
  if (!email) return "mailbox unavailable";
  const [local, domain] = email.split("@");
  if (!domain) return "mailbox unavailable";
  const visible = local.slice(0, Math.min(2, local.length));
  return `${visible}${"•".repeat(Math.max(3, Math.min(8, local.length - visible.length)))}@${domain}`;
}

export default async function StaffInvitationsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const ssr = await createSsrClient();
  const { data: { user: actor } } = await ssr.auth.getUser();
  if (!actor) notFound();
  const role = await activeStaffRole(ssr, actor.id, ["super_admin"]);
  if (role !== "super_admin") notFound();
  const params = await searchParams;
  if (process.env.ADMIN_INVITATION_LEDGER_UI === "true") {
    const cursor = invitationCursor(params);
    if (!cursor) return <div><ErrorPanel title="Invalid invitation cursor" detail="Restart the register to load recorded attempts." /><Link href="/staff/invitations" className="btn-secondary">Reset register</Link></div>;
    return <StaffInvitationRegister cursor={cursor} />;
  }
  const filters = directoryFilters(params);
  if (!filters) return <div><ErrorPanel title="Invalid staff filters" detail="Restart the invitation view with supported filters." /><Link href="/staff/invitations" className="btn-secondary">Reset staff filters</Link></div>;

  const db = await createAdminClient();
  const staffResult = await staffDirectoryQuery(db, filters);
  const staff = (staffResult.error ? [] : (staffResult.data ?? []).slice(0, STAFF_PAGE_SIZE)) as StaffRow[];
  const nextId = !staffResult.error && (staffResult.data?.length ?? 0) > STAFF_PAGE_SIZE ? staff.at(-1)?.user_id : undefined;
  const errors: string[] = staffResult.error ? ["Staff records could not be loaded. Refresh to retry."] : [];
  const invitations: InviteRow[] = [];

  try {
    createRequiredAuthAdminClient(); // Credential readiness only.
    let authAdmin: ReturnType<typeof createRequiredAuthAdminClient> | undefined;
    const resolved = await reconcileBounded(
      staff,
      5,
      6_000,
      async (member, signal) => ({
        member,
        auth: await (authAdmin ??= createRequiredAuthAdminClient(signal)).auth.admin.getUserById(member.user_id),
      }),
    );
    for (const lookup of resolved) {
      if (lookup.status !== "fulfilled") {
        if (!errors.includes("Some Auth checks failed or timed out. Refresh to retry.")) errors.push("Some Auth checks failed or timed out. Refresh to retry.");
        continue;
      }
      const { member, auth } = lookup.value;
      if (auth.error || !auth.data.user) {
        errors.push(`Auth record unavailable for staff ${member.user_id.slice(0, 8)}…`);
        continue;
      }
      const user = auth.data.user;
      const pendingFlag = user.app_metadata?.staff_invite_pending === true;
      if (!pendingFlag && user.email_confirmed_at && user.last_sign_in_at) continue;
      invitations.push({
        ...member,
        email: user.email ?? null,
        emailConfirmed: !!user.email_confirmed_at,
        pendingFlag,
        lastSignIn: user.last_sign_in_at ?? null,
        authCreatedAt: user.created_at,
      });
    }
  } catch (error) {
    errors.push(error instanceof Error ? error.message : "Auth invitation state unavailable");
  }

  const pending = invitations.filter((row) => row.pendingFlag).length;
  const unconfirmed = invitations.filter((row) => !row.emailConfirmed).length;
  const acceptedNotCompleted = invitations.filter((row) => row.emailConfirmed && row.pendingFlag).length;
  const complete = errors.length === 0;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Manage" title="Staff invitations" subtitle="Auth/database reconciliation for staff invitations without exposing member recovery data or listing the general Auth population." actions={<Link href="/staff" className="btn-secondary">Staff directory</Link>} />
      <DataWarning caveat title="Canonical invitation tracking is not active">
        The view reconciles accounts already carrying a staff role. An Auth
        invitation whose role assignment failed cannot be discovered safely by
        scanning millions of unrelated users; that requires a dedicated ledger.
      </DataWarning>
      <StaffDirectoryFilters filters={filters} path="/staff/invitations" />
      <p className="text-xs text-ink-muted">The following KPIs cover only this page of inspected staff, not all invitations.</p>
      {errors.length > 0 && <ErrorPanel title="Invitation picture is incomplete" detail={errors.join("\n")} />}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Metric label="Pending setup flag" value={complete ? pending : null} tone={pending > 0 ? "warn" : "ok"} />
        <Metric label="Email unconfirmed" value={complete ? unconfirmed : null} tone={unconfirmed > 0 ? "warn" : "ok"} />
        <Metric label="Accepted, setup incomplete" value={complete ? acceptedNotCompleted : null} tone={acceptedNotCompleted > 0 ? "danger" : "ok"} />
      </div>
      <Card title="Incomplete staff onboarding" hint="Mailbox is masked; exact address remains available in the restricted staff directory" padded={false}>
        {invitations.length === 0 ? (
          <EmptyState icon={<KeyRound size={32} />} title="No incomplete invitations derived on this page." hint={errors.length ? "The reconciliation is incomplete, so this is not proof that none exist." : "Inspect subsequent pages for other staff. Accounts without an assigned staff role are not covered by this view."} />
        ) : (
          <ul className="divide-y divide-line">
            {invitations.map((row) => (
              <li key={row.user_id} className="px-5 py-4">
                <div className="flex flex-wrap items-center gap-2">
                  <Link href={`/users/${row.user_id}`} className="font-bold text-burgundy hover:text-berry">{row.display_name}</Link>
                  <span className="text-xs text-ink-muted">@{row.anonymous_pseudonym}</span>
                  <Badge>{row.user_role.replaceAll("_", " ")}</Badge>
                  {!row.emailConfirmed && <Badge tone="warn">email unconfirmed</Badge>}
                  {row.pendingFlag && <Badge tone="danger">password setup pending</Badge>}
                </div>
                <p className="mt-1 text-xs text-ink-muted">{maskEmail(row.email)} · invited Auth account created {new Date(row.authCreatedAt).toLocaleString()}</p>
                <p className="mt-1 text-[11px] text-ink-muted">{row.lastSignIn ? `Last sign-in ${new Date(row.lastSignIn).toLocaleString()}` : "No completed sign-in"} · account {row.account_status}</p>
                {row.pendingFlag && <div className="mt-3 grid gap-4 md:grid-cols-2">
                  {!row.emailConfirmed && <WorkflowForm action={resendStaffInvite} blockUncertainRetry
                    disabled={process.env.ADMIN_STAFF_INVITES_DISABLED === "true"}
                    label="Resend invitation"
                    confirmation="Send the invitation email to this address again. Audited; no access changes.">
                    <input type="hidden" name="user_id" value={row.user_id} />
                    <label className="contact-field"><span>Reason</span>
                      <input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. first email went to spam" />
                    </label>
                  </WorkflowForm>}
                  <WorkflowForm action={revokeStaffInvite} blockUncertainRetry
                    label="Revoke invitation"
                    confirmation="Remove staff access and delete this unused account, so the link stops working. The audit history stays. You can invite the address again afterwards.">
                    <input type="hidden" name="user_id" value={row.user_id} />
                    <label className="contact-field"><span>Reason</span>
                      <input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. sent to the wrong address" />
                    </label>
                  </WorkflowForm>
                </div>}
              </li>
            ))}
          </ul>
        )}
      </Card>
      <StaffDirectoryPages filters={filters} nextId={nextId} path="/staff/invitations" />
      <CapabilityNotice title="Resend and revoke apply to unfinished invitations only">
        Resend works until the person opens the email. Once opened but not
        finished, revoke it and invite the address again. Anyone who has set a
        password is managed from the staff directory.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "ok" | "warn" | "danger" }) {
  return <Card><p className="h-eyebrow">{label} · this page</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "none on this page" : "review"}</Badge></div></Card>;
}
