import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type RoleRow = {
  user_id: string;
  anonymous_pseudonym: string;
  user_role: string;
  is_verified: boolean;
  created_at: string;
};

async function setRoleAction(formData: FormData) {
  "use server";
  const id = formData.get("id");
  const role = formData.get("role");
  if (typeof id !== "string" || typeof role !== "string") return;
  if (!["normal", "plug", "super_admin"].includes(role)) return;
  const db = createAdminClient();
  await db.from("users").update({ user_role: role }).eq("user_id", id);
  revalidatePath("/settings");
}

export default async function SettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const params = await searchParams;
  const q = params.q?.trim() ?? "";

  const db = createAdminClient();
  // Always show super_admins + plugs + the search-filtered set.
  const { data: privileged } = await db
    .from("users")
    .select("user_id, anonymous_pseudonym, user_role, is_verified, created_at")
    .in("user_role", ["super_admin", "plug"])
    .order("user_role", { ascending: true });

  let searched: RoleRow[] = [];
  if (q) {
    const { data } = await db
      .from("users")
      .select(
        "user_id, anonymous_pseudonym, user_role, is_verified, created_at"
      )
      .ilike("anonymous_pseudonym", `%${q}%`)
      .limit(40);
    searched = (data ?? []) as RoleRow[];
  }

  // De-dup by user_id, keeping the search row when both exist.
  const merged = new Map<string, RoleRow>();
  for (const r of (privileged ?? []) as RoleRow[]) merged.set(r.user_id, r);
  for (const r of searched) merged.set(r.user_id, r);
  const rows = [...merged.values()];

  const envFlags = [
    {
      key: "NEXT_PUBLIC_SUPABASE_URL",
      ok: !!process.env.NEXT_PUBLIC_SUPABASE_URL,
      sub: "Public — used by browser auth",
    },
    {
      key: "NEXT_PUBLIC_SUPABASE_ANON_KEY",
      ok: !!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
      sub: "Public — anon-role client",
    },
    {
      key: "SUPABASE_SERVICE_ROLE_KEY",
      ok: !!process.env.SUPABASE_SERVICE_ROLE_KEY,
      sub: "Server-only — bypasses RLS for admin reads",
    },
  ];

  return (
    <div className="flex flex-col gap-6 max-w-5xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Settings</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          Role assignment and environment status. Granting super_admin gives
          full operator access — use sparingly.
        </p>
      </div>

      {/* Env status */}
      <section className="card p-5">
        <h2 className="text-base font-extrabold text-burgundy mb-3">
          Environment
        </h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
          {envFlags.map((f) => (
            <div key={f.key} className="rounded-xl border border-mauve/30 p-3">
              <div className="flex items-center justify-between">
                <p className="text-[11px] font-bold uppercase tracking-widest text-burgundy/60">
                  {f.key}
                </p>
                <span
                  className={`pill ${
                    f.ok ? "bg-ok/15 text-ok" : "bg-danger/15 text-danger"
                  }`}
                >
                  {f.ok ? "set" : "missing"}
                </span>
              </div>
              <p className="mt-2 text-xs text-burgundy/65">{f.sub}</p>
            </div>
          ))}
        </div>
        <p className="mt-3 text-xs text-burgundy/55">
          Values are never displayed — only their presence is checked.
        </p>
      </section>

      {/* Moderation config */}
      <section className="card p-5">
        <h2 className="text-base font-extrabold text-burgundy mb-1">
          Moderation pipeline
        </h2>
        <p className="text-xs text-burgundy/55 mb-3">
          Settings live as Flutter <code>--dart-define</code> flags on the
          mobile client. Update the deploy config to change them.
        </p>
        <ul className="text-sm text-burgundy/85 space-y-2">
          <li>
            <span className="font-semibold">Tier 1</span> · always on; in-process keyword
            scan (self-harm, PII, hate, harassment, sexual content).
          </li>
          <li>
            <span className="font-semibold">Tier 2</span> · gated by
            <code className="bg-cardBlush rounded px-1 mx-1">GROQ_API_KEY</code>;
            chat-completion JSON-mode safety verdict using
            <code className="bg-cardBlush rounded px-1 mx-1">GROQ_GUARD_MODEL</code>
            (default: llama-3.3-70b-versatile).
          </li>
        </ul>
      </section>

      {/* Roles */}
      <section className="card p-5">
        <h2 className="text-base font-extrabold text-burgundy mb-1">
          Roles
        </h2>
        <p className="text-xs text-burgundy/55 mb-3">
          Lists every current super_admin + plug, plus any user matching your
          search. Promote / demote with the dropdown.
        </p>

        <form className="flex gap-3 mb-4" method="get">
          <input
            name="q"
            placeholder="Find a member by pseudonym…"
            defaultValue={q}
            className="rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm w-72"
          />
          <button className="btn-secondary" type="submit">
            Search
          </button>
          {q && (
            <a href="/settings" className="btn-secondary">
              Clear
            </a>
          )}
        </form>

        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-[11px] font-bold uppercase tracking-widest text-burgundy/55 bg-cardBlush/60">
              <tr>
                <th className="text-left px-4 py-3">Pseudonym</th>
                <th className="text-left px-4 py-3">Current role</th>
                <th className="text-left px-4 py-3">Joined</th>
                <th className="text-right px-4 py-3">Set role</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 && (
                <tr>
                  <td
                    colSpan={4}
                    className="text-center py-10 text-burgundy/55 italic"
                  >
                    {q
                      ? "No matches."
                      : "No privileged accounts yet."}
                  </td>
                </tr>
              )}
              {rows.map((u) => (
                <tr
                  key={u.user_id}
                  className="border-t border-mauve/20 hover:bg-cardBlush/40"
                >
                  <td className="px-4 py-3 font-semibold text-burgundy">
                    @{u.anonymous_pseudonym}
                    {u.is_verified && (
                      <span className="text-berry ml-1" title="Verified">
                        ✓
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3 text-burgundy/80">
                    <span
                      className={`pill ${
                        u.user_role === "super_admin"
                          ? "bg-berry/15 text-berry"
                          : u.user_role === "plug"
                            ? "bg-warn/15 text-warn"
                            : "bg-mauve/25 text-burgundy/70"
                      }`}
                    >
                      {u.user_role}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-burgundy/65">
                    {new Date(u.created_at).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-3">
                    <form
                      action={setRoleAction}
                      className="flex justify-end gap-2"
                    >
                      <input type="hidden" name="id" value={u.user_id} />
                      <select
                        name="role"
                        defaultValue={u.user_role}
                        className="rounded-xl border border-mauve/50 bg-white px-2 py-1 text-xs"
                      >
                        <option value="normal">normal</option>
                        <option value="plug">plug</option>
                        <option value="super_admin">super_admin</option>
                      </select>
                      <button className="btn-secondary" type="submit">
                        Apply
                      </button>
                    </form>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
