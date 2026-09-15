import Link from "next/link";
import { notFound } from "next/navigation";
import { mapBounded } from "@/lib/bounded";
import { activeStaffRole } from "@/lib/staff";
import {
  createAdminClient,
  createRequiredAuthAdminClient,
  createSsrClient,
} from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { ClipboardCheck } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const STAFF_ROLES = [
  "super_admin",
  "admin",
  "moderator",
  "support",
  "analyst",
  "read_only_auditor",
] as const;
const MAX_STAFF = 500;
const DORMANT_DAYS = 90;

type StaffRow = {
  user_id: string;
  display_name: string;
  anonymous_pseudonym: string;
  user_role: (typeof STAFF_ROLES)[number];
  account_status: string;
  deactivated_at: string | null;
  last_seen_at: string | null;
  created_at: string;
};

type Finding = StaffRow & {
  authLastSignIn: string | null;
  emailConfirmed: boolean | null;
  authDisabled: boolean | null;
  reasons: string[];
};

export default async function StaffAccessReviewsPage() {
  const ssr = await createSsrClient();
  const { data: { user: actor } } = await ssr.auth.getUser();
  if (!actor) notFound();
  const actorRole = await activeStaffRole(ssr, actor.id, ["super_admin"]);
  if (actorRole !== "super_admin") notFound();

  const db = await createAdminClient();
  const staffResult = await db
    .from("users")
    .select(
      "user_id, display_name, anonymous_pseudonym, user_role, account_status, deactivated_at, last_seen_at, created_at",
      { count: "exact" },
    )
    .in("user_role", STAFF_ROLES)
    .order("created_at", { ascending: false })
    .limit(MAX_STAFF);

  const errors: string[] = staffResult.error ? [staffResult.error.message] : [];
  const staff = (staffResult.data ?? []) as StaffRow[];
  const authById = new Map<string, {
    lastSignIn: string | null;
    emailConfirmed: boolean;
    disabled: boolean;
  }>();

  try {
    const authAdmin = createRequiredAuthAdminClient();
    const authRows = await mapBounded(staff, 10, async (member) => ({
      id: member.user_id,
      result: await authAdmin.auth.admin.getUserById(member.user_id),
    }));
    for (const row of authRows) {
      const authUser = row.result.data.user;
      if (row.result.error || !authUser) {
        errors.push(`Auth posture unavailable for staff ${row.id.slice(0, 8)}…`);
        continue;
      }
      authById.set(row.id, {
        lastSignIn: authUser.last_sign_in_at ?? null,
        emailConfirmed: !!authUser.email_confirmed_at,
        disabled: !!authUser.banned_until && new Date(authUser.banned_until) > new Date(),
      });
    }
  } catch (error) {
    errors.push(error instanceof Error ? error.message : "Auth staff posture is unavailable.");
  }

  const dormantBefore = Date.now() - DORMANT_DAYS * 86_400_000;
  const findings: Finding[] = staff.flatMap((member) => {
    const auth = authById.get(member.user_id);
    const lastActivity = auth?.lastSignIn ?? member.last_seen_at;
    const reasons: string[] = [];
    if (member.account_status !== "active" || member.deactivated_at) reasons.push("staff role on inactive account");
    if (auth?.disabled) reasons.push("Auth access disabled");
    if (auth && !auth.emailConfirmed) reasons.push("mailbox unconfirmed");
    if (!lastActivity) reasons.push("no completed activity");
    else if (new Date(lastActivity).getTime() < dormantBefore) reasons.push(`inactive for more than ${DORMANT_DAYS} days`);
    if (reasons.length === 0) return [];
    return [{
      ...member,
      authLastSignIn: auth?.lastSignIn ?? null,
      emailConfirmed: auth?.emailConfirmed ?? null,
      authDisabled: auth?.disabled ?? null,
      reasons,
    }];
  });
  const active = staff.filter((row) => row.account_status === "active" && !row.deactivated_at).length;
  const dormant = findings.filter((row) => row.reasons.some((reason) => reason.includes("inactive for"))).length;
  const inactiveWithRole = findings.filter((row) => row.reasons.includes("staff role on inactive account")).length;
  const truncated = (staffResult.count ?? 0) > MAX_STAFF;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader
        eyebrow="Manage"
        title="Staff access reviews"
        subtitle="Least-privilege review candidates derived from current staff, account, and Auth state. Mailboxes, factors, recovery data, and session identifiers are not displayed."
        actions={<Link href="/staff" className="btn-secondary">Staff directory</Link>}
      />
      <DataWarning title="This view identifies candidates; it does not certify access">
        Venttly does not yet have an owner, review period, attestation, exception,
        or expiry ledger. A green row would only mean that no current heuristic
        matched—not that the access was independently approved.
      </DataWarning>
      {(errors.length > 0 || truncated) && (
        <ErrorPanel
          title="Access-review evidence is incomplete"
          detail={[...errors, ...(truncated ? [`Only the newest ${MAX_STAFF} staff records were inspected.`] : [])].join("\n")}
          hint="Unknown Auth state is never treated as compliant."
        />
      )}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Staff inspected" value={staffResult.error ? null : staff.length} tone="neutral" />
        <Metric label="Active access" value={staffResult.error ? null : active} tone="ok" />
        <Metric label={`Dormant · ${DORMANT_DAYS}d`} value={staffResult.error ? null : dormant} tone={dormant ? "warn" : "ok"} />
        <Metric label="Inactive with role" value={staffResult.error ? null : inactiveWithRole} tone={inactiveWithRole ? "danger" : "ok"} />
      </div>
      <Card title="Review candidates" hint="Most recent staff records; no automatic revocation" padded={false}>
        {findings.length === 0 ? (
          <EmptyState
            icon={<ClipboardCheck size={32} />}
            title="No review candidates were derived."
            hint={errors.length || truncated ? "Evidence is incomplete, so this is not a clean certification." : "Create a formal periodic review before treating this result as assurance."}
          />
        ) : (
          <ul className="divide-y divide-line">
            {findings.map((row) => (
              <li key={row.user_id} className="px-5 py-4">
                <div className="flex flex-wrap items-center gap-2">
                  <Link href={`/users/${row.user_id}`} className="font-bold text-burgundy hover:text-berry">{row.display_name}</Link>
                  <span className="text-xs text-ink-muted">@{row.anonymous_pseudonym}</span>
                  <Badge>{row.user_role.replaceAll("_", " ")}</Badge>
                  {row.reasons.map((reason) => <Badge key={reason} tone={reason.includes("inactive account") ? "danger" : "warn"}>{reason}</Badge>)}
                </div>
                <p className="mt-1 text-[11px] text-ink-muted">
                  {row.authLastSignIn ? `Last Auth sign-in ${new Date(row.authLastSignIn).toLocaleString()}` : row.last_seen_at ? `Last app activity ${new Date(row.last_seen_at).toLocaleString()}` : "No activity timestamp"}
                </p>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <CapabilityNotice title="Certification and revocation need an actor-bound workflow">
        The backend phase must add review campaigns, scoped entitlements,
        reviewer separation, due dates, attest/reject decisions, temporary
        exceptions, automatic expiry, session revocation, and immutable audit
        records. Existing staff mutations remain on the MFA-protected directory.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "neutral" | "ok" | "warn" | "danger" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "clear" : tone === "neutral" ? "observed" : "review"}</Badge></div></Card>;
}
