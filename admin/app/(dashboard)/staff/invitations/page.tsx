import Link from "next/link";
import { notFound } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { mapBounded } from "@/lib/bounded";
import { createAdminClient, createRequiredAuthAdminClient, createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { KeyRound } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const STAFF_ROLES = ["super_admin", "admin", "moderator", "support", "analyst", "read_only_auditor"] as const;

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

export default async function StaffInvitationsPage() {
  const ssr = await createSsrClient();
  const { data: { user: actor } } = await ssr.auth.getUser();
  if (!actor) notFound();
  const role = await activeStaffRole(ssr, actor.id, ["super_admin"]);
  if (role !== "super_admin") notFound();

  const db = await createAdminClient();
  const staffResult = await db.from("users").select("user_id, display_name, anonymous_pseudonym, user_role, account_status, created_at", { count: "exact" }).in("user_role", STAFF_ROLES).order("created_at", { ascending: false }).limit(500);
  const errors: string[] = staffResult.error ? [staffResult.error.message] : [];
  const invitations: InviteRow[] = [];

  try {
    const authAdmin = createRequiredAuthAdminClient();
    const resolved = await mapBounded(
      (staffResult.data ?? []) as StaffRow[],
      10,
      async (member) => ({
        member,
        auth: await authAdmin.auth.admin.getUserById(member.user_id),
      }),
    );
    for (const { member, auth } of resolved) {
      if (auth.error || !auth.data.user) {
        errors.push(`Auth record unavailable for staff ${member.user_id.slice(0, 8)}…`);
        continue;
      }
      const user = auth.data.user;
      const pendingFlag = user.app_metadata.staff_invite_pending === true;
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
  const truncated = (staffResult.count ?? 0) > 500;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Manage" title="Staff invitations" subtitle="Auth/database reconciliation for staff invitations without exposing member recovery data or listing the general Auth population." actions={<Link href="/staff" className="btn-secondary">Staff directory</Link>} />
      <DataWarning title="This is not yet a canonical invitation ledger">
        The view reconciles accounts already carrying a staff role. An Auth
        invitation whose role assignment failed cannot be discovered safely by
        scanning millions of unrelated users; that requires a dedicated ledger.
      </DataWarning>
      {(errors.length > 0 || truncated) && <ErrorPanel title="Invitation picture is incomplete" detail={[...errors, ...(truncated ? ["Only the newest 500 staff records were inspected."] : [])].join("\n")} />}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Metric label="Pending setup flag" value={pending} tone={pending > 0 ? "warn" : "ok"} />
        <Metric label="Email unconfirmed" value={unconfirmed} tone={unconfirmed > 0 ? "warn" : "ok"} />
        <Metric label="Accepted, setup incomplete" value={acceptedNotCompleted} tone={acceptedNotCompleted > 0 ? "danger" : "ok"} />
      </div>
      <Card title="Incomplete staff onboarding" hint="Mailbox is masked; exact address remains available in the restricted staff directory" padded={false}>
        {invitations.length === 0 ? (
          <EmptyState icon={<KeyRound size={32} />} title="No incomplete invitations returned." hint={errors.length || truncated ? "The reconciliation is incomplete, so this is not proof that none exist." : "Every resolved staff account has confirmed email, consumed setup state, and signed in."} />
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
              </li>
            ))}
          </ul>
        )}
      </Card>
      <CapabilityNotice title="Resend, revoke, and reconcile controls remain unavailable">
        The backend phase must add an idempotency key, hashed invitation address,
        requested role, inviter, expiry, state transitions, cancellation,
        delivery attempts, Auth user ID, and transactional consume/reconcile
        operations. Blindly sending another Auth invitation can create ambiguous
        state and should not be a UI-only retry.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number; tone: "ok" | "warn" | "danger" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value}</p><Badge tone={tone}>{tone === "ok" ? "clear" : "review"}</Badge></div></Card>;
}
