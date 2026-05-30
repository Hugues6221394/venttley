import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { CheckCircle2, KeyRound, XCircle } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Role =
  | "super_admin"
  | "admin"
  | "moderator"
  | "support"
  | "analyst"
  | "read_only_auditor"
  | "plug"
  | "normal";

type Cap =
  | "view_dashboard"
  | "view_audit"
  | "moderate"
  | "user_admin"
  | "tribe_admin"
  | "broadcast"
  | "feature_flags"
  | "assign_roles"
  | "export";

const CAP_LABEL: Record<Cap, string> = {
  view_dashboard: "View dashboard",
  view_audit: "View audit log",
  moderate: "Moderate content & accounts",
  user_admin: "Suspend / ban users",
  tribe_admin: "Feature / archive tribes",
  broadcast: "Send broadcasts",
  feature_flags: "Toggle feature flags",
  assign_roles: "Assign staff roles",
  export: "Export CSV reports",
};

const MATRIX: Record<Role, Set<Cap>> = {
  super_admin: new Set([
    "view_dashboard",
    "view_audit",
    "moderate",
    "user_admin",
    "tribe_admin",
    "broadcast",
    "feature_flags",
    "assign_roles",
    "export",
  ]),
  admin: new Set([
    "view_dashboard",
    "view_audit",
    "moderate",
    "user_admin",
    "tribe_admin",
    "broadcast",
    "feature_flags",
    "export",
  ]),
  moderator: new Set(["view_dashboard", "moderate", "user_admin"]),
  support: new Set(["view_dashboard"]),
  analyst: new Set(["view_dashboard", "export"]),
  read_only_auditor: new Set(["view_dashboard", "view_audit", "export"]),
  plug: new Set([]),
  normal: new Set([]),
};

const ROLE_TONE: Record<Role, "danger" | "info" | "warn" | "ok" | "neutral"> = {
  super_admin: "danger",
  admin: "info",
  moderator: "info",
  support: "warn",
  analyst: "warn",
  read_only_auditor: "warn",
  plug: "ok",
  normal: "neutral",
};

const ROLES: Role[] = [
  "super_admin",
  "admin",
  "moderator",
  "support",
  "analyst",
  "read_only_auditor",
  "plug",
  "normal",
];
const CAPS: Cap[] = [
  "view_dashboard",
  "view_audit",
  "moderate",
  "user_admin",
  "tribe_admin",
  "broadcast",
  "feature_flags",
  "assign_roles",
  "export",
];

export default async function RolesPage() {
  const db = createAdminClient();
  const { data: staff } = await db
    .from("users")
    .select("user_id, anonymous_pseudonym, user_role, account_status, created_at")
    .in("user_role", [
      "super_admin",
      "admin",
      "moderator",
      "support",
      "analyst",
      "read_only_auditor",
    ])
    .order("user_role");

  const { data: roleChanges } = await db
    .from("audit_log")
    .select("audit_id, actor_pseudonym, target_label, before_state, after_state, reason, created_at")
    .eq("action", "user.set_role")
    .order("created_at", { ascending: false })
    .limit(20);

  return (
    <div className="flex flex-col gap-6 max-w-[1300px]">
      <PageHeader
        eyebrow="Manage"
        title="Roles & permissions"
        subtitle="Who can do what on Venttly. Capabilities are enforced at the database via SECURITY DEFINER RPCs — this matrix mirrors that policy."
        actions={
          <Link href="/audit?action=user.set_role" className="btn-secondary">
            Role-change history
          </Link>
        }
      />

      <Card title="Permission matrix" hint="Roles down, capabilities across" padded={false}>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-canvas/70">
              <tr>
                <th className="t-th">Role</th>
                {CAPS.map((c) => (
                  <th key={c} className="t-th text-center">
                    {CAP_LABEL[c]}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ROLES.map((r) => (
                <tr key={r} className="t-row">
                  <td className="t-td">
                    <Badge tone={ROLE_TONE[r]}>{r}</Badge>
                  </td>
                  {CAPS.map((c) => (
                    <td key={c} className="t-td text-center">
                      {MATRIX[r].has(c) ? (
                        <CheckCircle2
                          size={16}
                          className="text-ok inline"
                        />
                      ) : (
                        <XCircle
                          size={16}
                          className="text-ink-muted/40 inline"
                        />
                      )}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="px-5 pb-4 pt-2 text-[11px] text-ink-muted">
          Only <code className="font-mono">super_admin</code> can assign staff
          roles — enforced by{" "}
          <code className="font-mono">admin_set_user_role</code> (migration 0022).
        </p>
      </Card>

      <Card title="Current staff" hint="Users with any staff role" padded={false}>
        {((staff ?? []) as unknown[]).length === 0 ? (
          <div className="px-5 py-10 text-sm text-ink-muted italic">
            No staff users yet. Assign a role from a user&rsquo;s detail page.
          </div>
        ) : (
          <ul className="divide-y divide-line">
            {(
              (staff ?? []) as {
                user_id: string;
                anonymous_pseudonym: string;
                user_role: Role;
                account_status: string;
                created_at: string;
              }[]
            ).map((u) => (
              <li
                key={u.user_id}
                className="px-5 py-3 flex items-center gap-3"
              >
                <KeyRound size={14} className="text-berry" />
                <Link
                  href={`/users/${u.user_id}`}
                  className="text-sm font-semibold text-burgundy hover:text-berry"
                >
                  @{u.anonymous_pseudonym}
                </Link>
                <Badge tone={ROLE_TONE[u.user_role]}>{u.user_role}</Badge>
                <Badge
                  tone={u.account_status === "active" ? "ok" : "warn"}
                >
                  {u.account_status}
                </Badge>
                <p className="ml-auto text-[11px] text-ink-muted">
                  joined {new Date(u.created_at).toLocaleDateString()}
                </p>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card title="Recent role changes" hint="Last 20 role assignments" padded={false}>
        {((roleChanges ?? []) as unknown[]).length === 0 ? (
          <div className="px-5 py-10 text-sm text-ink-muted italic">
            No role changes yet.
          </div>
        ) : (
          <ul className="divide-y divide-line">
            {(
              (roleChanges ?? []) as {
                audit_id: string;
                actor_pseudonym: string;
                target_label: string | null;
                before_state: { user_role?: string } | null;
                after_state: { user_role?: string } | null;
                reason: string | null;
                created_at: string;
              }[]
            ).map((r) => (
              <li
                key={r.audit_id}
                className="px-5 py-3 flex items-center gap-3 flex-wrap"
              >
                <span className="text-sm text-burgundy">
                  <span className="font-bold">@{r.actor_pseudonym}</span>
                  {" set "}
                  <span className="font-mono">{r.target_label}</span>
                  {" from "}
                  <Badge tone="neutral">
                    {r.before_state?.user_role ?? "—"}
                  </Badge>
                  {" → "}
                  <Badge tone="info">
                    {r.after_state?.user_role ?? "—"}
                  </Badge>
                </span>
                {r.reason && (
                  <span className="text-xs text-ink-muted italic">
                    “{r.reason}”
                  </span>
                )}
                <span className="text-[11px] text-ink-muted ml-auto">
                  {new Date(r.created_at).toLocaleString()}
                </span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
