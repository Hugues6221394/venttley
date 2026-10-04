import Link from "next/link";
import { notFound } from "next/navigation";
import { reconcileBounded } from "@/lib/bounded";
import { directoryFilters, directoryRoles, STAFF_PAGE_SIZE, staffDirectoryQuery } from "@/lib/staff-directory-model";
import { StaffDirectoryFilters, StaffDirectoryPages } from "@/components/staff-directory-controls";
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
import { reviewFilters } from "@/lib/access-review-model";
import { AccessReviewRegister } from "@/components/workflows/access-review-register";

export const dynamic = "force-dynamic";

const STAFF_ROLES = directoryRoles;
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

export default async function StaffAccessReviewsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const ssr = await createSsrClient();
  const { data: { user: actor } } = await ssr.auth.getUser();
  if (!actor) notFound();
  const actorRole = await activeStaffRole(ssr, actor.id, ["super_admin"]);
  if (actorRole !== "super_admin") notFound();
  const params = await searchParams;
  if (process.env.ADMIN_ACCESS_REVIEWS_UI === "true") {
    const review = reviewFilters(params);
    if (!review) return <ErrorPanel title="Invalid review filters" detail="Return to the access-review page without cursor parameters." />;
    return <AccessReviewRegister filters={review}/>;
  }
  const filters = directoryFilters(params);
  if (!filters) return <div><ErrorPanel title="Invalid staff filters" detail="Restart the access-review view with supported filters." /><Link href="/staff/access-reviews" className="btn-secondary">Reset staff filters</Link></div>;

  const db = await createAdminClient();
  const staffResult = await staffDirectoryQuery(db, filters);

  const errors: string[] = staffResult.error ? ["Staff records could not be loaded. Refresh to retry."] : [];
  const staff = (staffResult.error ? [] : (staffResult.data ?? []).slice(0, STAFF_PAGE_SIZE)) as StaffRow[];
  const nextId = !staffResult.error && (staffResult.data?.length ?? 0) > STAFF_PAGE_SIZE ? staff.at(-1)?.user_id : undefined;
  const authById = new Map<string, {
    lastSignIn: string | null;
    emailConfirmed: boolean;
    disabled: boolean;
  }>();

  try {
    createRequiredAuthAdminClient(); // Credential readiness only.
    let authAdmin: ReturnType<typeof createRequiredAuthAdminClient> | undefined;
    const authRows = await reconcileBounded(staff, 5, 6_000, async (member, signal) => ({
      id: member.user_id,
      result: await (authAdmin ??= createRequiredAuthAdminClient(signal)).auth.admin.getUserById(member.user_id),
    }));
    for (const lookup of authRows) {
      if (lookup.status !== "fulfilled") {
        if (!errors.includes("Some Auth checks failed or timed out. Refresh to retry.")) errors.push("Some Auth checks failed or timed out. Refresh to retry.");
        continue;
      }
      const row = lookup.value;
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
    if (!auth) reasons.push("Auth posture unknown");
    if (member.account_status !== "active" || member.deactivated_at) reasons.push("staff role on inactive account");
    if (auth?.disabled) reasons.push("Auth access disabled");
    if (auth && !auth.emailConfirmed) reasons.push("mailbox unconfirmed");
    if (auth && !lastActivity) reasons.push("no completed activity");
    else if (auth && lastActivity && new Date(lastActivity).getTime() < dormantBefore) reasons.push(`inactive for more than ${DORMANT_DAYS} days`);
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

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader
        eyebrow="Manage"
        title="Staff access reviews"
        subtitle="Least-privilege review candidates derived from current staff, account, and Auth state. Mailboxes, factors, recovery data, and session identifiers are not displayed."
        actions={<Link href="/staff" className="btn-secondary">Staff directory</Link>}
      />
      <DataWarning title="This view identifies candidates; it does not certify access">
        The canonical review pilot is not active in this view. A green row only
        means that no current heuristic matched—not that access was independently
        approved. Formal review decisions must not be inferred from these checks.
      </DataWarning>
      <StaffDirectoryFilters filters={filters} path="/staff/access-reviews" />
      <p className="text-xs text-ink-muted">The following KPIs cover only this page of inspected staff, not an organization-wide certification.</p>
      {errors.length > 0 && (
        <ErrorPanel
          title="Access-review evidence is incomplete"
          detail={errors.join("\n")}
          hint="Unknown Auth state is never treated as compliant."
        />
      )}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Staff inspected" value={staffResult.error ? null : staff.length} tone="neutral" />
        <Metric label="Active profile rows inspected" value={staffResult.error ? null : active} tone="neutral" />
        <Metric label={`Dormant · ${DORMANT_DAYS}d`} value={errors.length ? null : dormant} tone={dormant ? "warn" : "ok"} />
        <Metric label="Inactive with role" value={staffResult.error ? null : inactiveWithRole} tone={inactiveWithRole ? "danger" : "ok"} />
      </div>
      <Card title="Review candidates" hint="Findings from this staff page; no automatic revocation" padded={false}>
        {findings.length === 0 ? (
          <EmptyState
            icon={<ClipboardCheck size={32} />}
            title="No review candidates were derived on this page."
            hint={errors.length ? "Evidence is incomplete, so this is not a clean certification." : "Continue through the staff pages. A formal periodic review is required before treating any result as assurance."}
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
                  {row.authLastSignIn ? `Last Auth sign-in ${new Date(row.authLastSignIn).toLocaleString()}` : row.last_seen_at ? `Last app activity ${new Date(row.last_seen_at).toLocaleString()}` : row.authDisabled === null ? "Activity unknown" : "No activity timestamp"}
                </p>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <StaffDirectoryPages filters={filters} nextId={nextId} path="/staff/access-reviews" />
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
  return <Card><p className="h-eyebrow">{label} · this page</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "none on this page" : tone === "neutral" ? "observed" : "review"}</Badge></div></Card>;
}
