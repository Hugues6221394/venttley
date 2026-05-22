import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type Row = {
  user_id: string;
  anonymous_pseudonym: string;
  avatar_seed: string;
  user_role: string;
  safety_tier: string;
  account_status: string;
  birth_year: number | null;
  created_at: string;
};

async function setStatusAction(formData: FormData) {
  "use server";
  const id = formData.get("id");
  const status = formData.get("status");
  if (typeof id !== "string" || typeof status !== "string") return;
  const db = createAdminClient();
  await db
    .from("users")
    .update({ account_status: status })
    .eq("user_id", id);
  revalidatePath("/users");
}

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; status?: string }>;
}) {
  const params = await searchParams;
  const q = params.q?.trim() ?? "";
  const status = params.status ?? "";

  const db = createAdminClient();
  let query = db
    .from("users")
    .select(
      "user_id, anonymous_pseudonym, avatar_seed, user_role, safety_tier, account_status, birth_year, created_at"
    )
    .order("created_at", { ascending: false })
    .limit(200);
  if (q) query = query.ilike("anonymous_pseudonym", `%${q}%`);
  if (status) query = query.eq("account_status", status);
  const { data, error } = await query;
  const rows = (data ?? []) as Row[];

  return (
    <div className="flex flex-col gap-6 max-w-6xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Users</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          Member accounts. Suspend or restore via the per-row controls.
        </p>
      </div>

      <form className="flex gap-3" method="get">
        <input
          name="q"
          placeholder="Search pseudonym…"
          defaultValue={q}
          className="rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm w-72"
        />
        <select
          name="status"
          defaultValue={status}
          className="rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm"
        >
          <option value="">All statuses</option>
          <option value="active">Active</option>
          <option value="suspended">Suspended</option>
          <option value="banned">Banned</option>
        </select>
        <button className="btn-secondary" type="submit">
          Apply
        </button>
        {(q || status) && (
          <a href="/users" className="btn-secondary">
            Clear
          </a>
        )}
      </form>

      {error && (
        <div className="card p-4 border-danger/30 text-danger">
          Could not load users: {error.message}
        </div>
      )}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="text-[11px] font-bold uppercase tracking-widest text-burgundy/55 bg-cardBlush/60">
            <tr>
              <th className="text-left px-4 py-3">Pseudonym</th>
              <th className="text-left px-4 py-3">Role</th>
              <th className="text-left px-4 py-3">Tier</th>
              <th className="text-left px-4 py-3">Status</th>
              <th className="text-left px-4 py-3">Joined</th>
              <th className="text-right px-4 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td
                  colSpan={6}
                  className="text-center py-12 text-burgundy/55 italic"
                >
                  No users match the current filter.
                </td>
              </tr>
            )}
            {rows.map((u) => {
              const badgeTone =
                u.account_status === "active"
                  ? "bg-ok/15 text-ok"
                  : u.account_status === "suspended"
                    ? "bg-warn/15 text-warn"
                    : "bg-danger/15 text-danger";
              return (
                <tr
                  key={u.user_id}
                  className="border-t border-mauve/20 hover:bg-cardBlush/40"
                >
                  <td className="px-4 py-3 font-semibold text-burgundy">
                    @{u.anonymous_pseudonym}
                  </td>
                  <td className="px-4 py-3 text-burgundy/80">{u.user_role}</td>
                  <td className="px-4 py-3 text-burgundy/80">
                    {u.safety_tier}
                  </td>
                  <td className="px-4 py-3">
                    <span className={`pill ${badgeTone}`}>
                      {u.account_status}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-burgundy/65">
                    {new Date(u.created_at).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex gap-2 justify-end">
                      {u.account_status === "active" ? (
                        <form action={setStatusAction}>
                          <input type="hidden" name="id" value={u.user_id} />
                          <input type="hidden" name="status" value="suspended" />
                          <button className="btn-secondary" type="submit">
                            Suspend
                          </button>
                        </form>
                      ) : (
                        <form action={setStatusAction}>
                          <input type="hidden" name="id" value={u.user_id} />
                          <input type="hidden" name="status" value="active" />
                          <button className="btn-secondary" type="submit">
                            Reactivate
                          </button>
                        </form>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-burgundy/55">
        Returns up to 200 most recent matches. Showing only the safe columns
        (no recovery hashes, no auth secrets).
      </p>
    </div>
  );
}
