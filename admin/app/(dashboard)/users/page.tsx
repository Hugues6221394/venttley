import Link from "next/link";
import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import {
  Ban,
  CheckCircle2,
  ChevronRight,
  EyeOff,
  Search,
  Users as UsersIcon,
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
const STATUSES = ["active", "suspended", "banned", "shadow_banned"];

type Row = {
  user_id: string;
  anonymous_pseudonym: string;
  avatar_seed: string;
  user_role: string;
  safety_tier: string;
  account_status: string;
  karma_points: number;
  home_country: string | null;
  created_at: string;
};

// ──────────────────────────── Server actions ────────────────────────────

async function setStatusAction(formData: FormData) {
  "use server";
  const id = String(formData.get("user_id") ?? "");
  const status = String(formData.get("status") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!id || !status) return;
  await rpc("admin_set_user_status", {
    p_target: id,
    p_status: status,
    p_reason: reason || null,
  });
  revalidatePath("/users");
}

// ──────────────────────────── Page ────────────────────────────

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; status?: string; role?: string; country?: string }>;
}) {
  const params = await searchParams;
  const q = params.q?.trim() ?? "";
  const status = params.status ?? "";
  const role = params.role ?? "";
  const country = params.country ?? "";

  const db = await createAdminClient();
  let query = db
    .from("users")
    .select(
      "user_id, anonymous_pseudonym, avatar_seed, user_role, safety_tier, account_status, karma_points, home_country, created_at"
    )
    .order("created_at", { ascending: false })
    .limit(200);
  if (q) query = query.ilike("anonymous_pseudonym", `%${q}%`);
  if (status) query = query.eq("account_status", status);
  if (role) query = query.eq("user_role", role);
  if (country) query = query.eq("home_country", country);
  const { data, error } = await query;
  const rows = (data ?? []) as Row[];

  const [{ count: totalUsers }, { count: activeUsers }, { count: suspended }] =
    await Promise.all([
      db.from("users").select("user_id", { count: "exact", head: true }),
      db
        .from("users")
        .select("user_id", { count: "exact", head: true })
        .eq("account_status", "active"),
      db
        .from("users")
        .select("user_id", { count: "exact", head: true })
        .in("account_status", ["suspended", "banned", "shadow_banned"]),
    ]);

  return (
    <div className="flex flex-col gap-6 max-w-[1300px]">
      <PageHeader
        eyebrow="Manage"
        title="Users"
        subtitle="Search, inspect, and act on individual accounts. Open a user to see their full activity timeline."
        actions={
          <span className="text-xs text-ink-muted">
            {(totalUsers ?? 0).toLocaleString()} total · {(activeUsers ?? 0).toLocaleString()} active
            {(suspended ?? 0) > 0 && (
              <>
                {" · "}
                <span className="text-danger">{suspended}</span> restricted
              </>
            )}
          </span>
        }
      />

      <Card padded>
        <form className="flex flex-wrap gap-3 items-end" method="get">
          <div className="flex-1 min-w-[240px]">
            <label className="h-eyebrow block mb-1">Pseudonym</label>
            <div className="relative">
              <Search
                size={14}
                className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted"
              />
              <input
                name="q"
                placeholder="e.g. midnight_soul"
                defaultValue={q}
                className="input pl-9"
              />
            </div>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Status</label>
            <select name="status" defaultValue={status} className="select">
              <option value="">All</option>
              {STATUSES.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Role</label>
            <select name="role" defaultValue={role} className="select">
              <option value="">All</option>
              {ROLES.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Country</label>
            <input
              name="country"
              placeholder="ISO code"
              defaultValue={country}
              className="input w-32"
            />
          </div>
          <button className="btn-secondary" type="submit">
            Apply
          </button>
          {(q || status || role || country) && (
            <a href="/users" className="btn-ghost">
              Clear
            </a>
          )}
        </form>
      </Card>

      {error && (
        <Card padded>
          <p className="text-sm text-danger">
            Could not load users: {error.message}
          </p>
        </Card>
      )}

      {rows.length === 0 ? (
        <Card padded>
          <EmptyState
            icon={<UsersIcon size={32} />}
            title="No users match the filter."
            hint="Try clearing the filters or searching by a partial pseudonym."
          />
        </Card>
      ) : (
        <div className="surface overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-canvas/70">
                <tr>
                  <th className="t-th">Pseudonym</th>
                  <th className="t-th">Role</th>
                  <th className="t-th">Tier</th>
                  <th className="t-th">Status</th>
                  <th className="t-th text-right">Karma</th>
                  <th className="t-th">Country</th>
                  <th className="t-th">Joined</th>
                  <th className="t-th text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((u) => (
                  <tr key={u.user_id} className="t-row">
                    <td className="t-td">
                      <Link
                        href={`/users/${u.user_id}`}
                        className="font-semibold text-burgundy hover:text-berry"
                      >
                        @{u.anonymous_pseudonym}
                      </Link>
                    </td>
                    <td className="t-td">
                      <Badge tone={u.user_role === "super_admin" ? "danger" : u.user_role === "admin" || u.user_role === "moderator" ? "info" : "neutral"}>
                        {u.user_role}
                      </Badge>
                    </td>
                    <td className="t-td text-ink-muted">{u.safety_tier}</td>
                    <td className="t-td">
                      <StatusBadge status={u.account_status} />
                    </td>
                    <td className="t-td text-right tabular text-ink-muted">
                      {u.karma_points.toLocaleString()}
                    </td>
                    <td className="t-td text-ink-muted">
                      {u.home_country ?? "—"}
                    </td>
                    <td className="t-td text-ink-muted">
                      {new Date(u.created_at).toLocaleDateString()}
                    </td>
                    <td className="t-td text-right">
                      <div className="flex gap-1.5 justify-end">
                        {u.account_status === "active" ? (
                          <QuickAction
                            action={setStatusAction}
                            userId={u.user_id}
                            status="suspended"
                            label="Suspend"
                            icon={<Ban size={13} />}
                          />
                        ) : (
                          <QuickAction
                            action={setStatusAction}
                            userId={u.user_id}
                            status="active"
                            label="Reactivate"
                            icon={<CheckCircle2 size={13} />}
                          />
                        )}
                        <Link
                          href={`/users/${u.user_id}`}
                          className="btn-ghost"
                        >
                          Open <ChevronRight size={13} />
                        </Link>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <p className="text-xs text-ink-muted">
        Returns up to 200 most recent matches. Sensitive fields (recovery
        secrets) are never read by the console.
      </p>
    </div>
  );
}

// ──────────────────────────── helpers ────────────────────────────

function StatusBadge({ status }: { status: string }) {
  if (status === "active") return <Badge tone="ok">active</Badge>;
  if (status === "suspended") return <Badge tone="warn">suspended</Badge>;
  if (status === "shadow_banned")
    return (
      <Badge tone="danger" icon={<EyeOff size={11} />}>
        shadow-banned
      </Badge>
    );
  return <Badge tone="danger">{status}</Badge>;
}

function QuickAction({
  action,
  userId,
  status,
  label,
  icon,
}: {
  action: (fd: FormData) => Promise<void>;
  userId: string;
  status: string;
  label: string;
  icon: React.ReactNode;
}) {
  return (
    <form action={action}>
      <input type="hidden" name="user_id" value={userId} />
      <input type="hidden" name="status" value={status} />
      <button className="btn-ghost" type="submit">
        {icon}
        {label}
      </button>
    </form>
  );
}
