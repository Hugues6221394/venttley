import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";

export const dynamic = "force-dynamic";

type IpRow = {
  ip: string;
  user_id: string | null;
  pseudonym: string | null;
  last_seen: string | null;
  session_count: number;
};

export default async function SessionsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const sp = await searchParams;
  const q = (sp.q ?? "").trim().toLowerCase();

  const db = await createAdminClient();
  const { data, error } = await db.rpc("admin_recent_ips", { p_limit: 300 });
  const rows = ((data ?? []) as IpRow[]).filter(
    (r) =>
      !q ||
      r.ip?.toLowerCase().includes(q) ||
      (r.pseudonym ?? "").toLowerCase().includes(q)
  );

  const uniqueIps = new Set(rows.map((r) => r.ip)).size;
  const totalSessions = rows.reduce((n, r) => n + (r.session_count ?? 0), 0);

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <PageHeader
        eyebrow="Security"
        title="Sessions & IP addresses"
        subtitle="Active GoTrue sessions across all accounts, grouped by IP. super_admin only — reads auth.sessions via admin_recent_ips()."
      />

      {error ? (
        <Card padded>
          <p className="text-sm text-red-600">
            Couldn&rsquo;t load sessions: {error.message}. This view requires{" "}
            <code className="font-mono">super_admin</code>.
          </p>
        </Card>
      ) : (
        <>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
            <Card padded>
              <p className="h-eyebrow mb-1">Distinct IPs</p>
              <p className="tabular text-2xl font-extrabold text-burgundy">
                {uniqueIps}
              </p>
            </Card>
            <Card padded>
              <p className="h-eyebrow mb-1">Active sessions</p>
              <p className="tabular text-2xl font-extrabold text-burgundy">
                {totalSessions}
              </p>
            </Card>
            <Card padded>
              <p className="h-eyebrow mb-1">Accounts online</p>
              <p className="tabular text-2xl font-extrabold text-burgundy">
                {new Set(rows.map((r) => r.user_id).filter(Boolean)).size}
              </p>
            </Card>
          </div>

          <Card
            title="Recent IPs"
            hint="Most recently active first. Tap a user to open their profile."
            padded={false}
          >
            <div className="px-5 py-3 border-b border-line">
              <form method="get" className="flex gap-2">
                <input
                  type="text"
                  name="q"
                  defaultValue={sp.q ?? ""}
                  placeholder="filter by IP or @pseudonym"
                  className="input flex-1"
                />
                <button type="submit" className="btn-secondary">
                  Filter
                </button>
              </form>
            </div>
            {rows.length === 0 ? (
              <div className="px-5 py-10 text-sm text-ink-muted italic">
                No sessions found.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="bg-canvas/70">
                    <tr>
                      <th className="t-th">IP address</th>
                      <th className="t-th">Account</th>
                      <th className="t-th text-center">Sessions</th>
                      <th className="t-th">Last seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((r, i) => (
                      <tr key={`${r.ip}-${r.user_id}-${i}`} className="t-row">
                        <td className="t-td font-mono text-xs select-all">
                          {r.ip}
                        </td>
                        <td className="t-td">
                          {r.user_id ? (
                            <Link
                              href={`/users/${r.user_id}`}
                              className="font-semibold text-burgundy hover:text-berry"
                            >
                              @{r.pseudonym ?? "—"}
                            </Link>
                          ) : (
                            <span className="text-ink-muted">—</span>
                          )}
                        </td>
                        <td className="t-td text-center tabular">
                          {r.session_count}
                        </td>
                        <td className="t-td text-ink-muted whitespace-nowrap">
                          {r.last_seen
                            ? new Date(r.last_seen).toLocaleString()
                            : "—"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </div>
  );
}
