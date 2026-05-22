import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type Row = {
  tribe_id: string;
  name: string;
  slug: string;
  category: string;
  description: string | null;
  member_count: number;
  is_private: boolean;
  is_featured: boolean;
  is_suspended: boolean;
  created_at: string;
  keeper_id: string | null;
  users: { anonymous_pseudonym: string; is_verified: boolean } | null;
};

async function toggleFeaturedAction(formData: FormData) {
  "use server";
  const id = formData.get("id");
  const next = formData.get("next");
  if (typeof id !== "string" || typeof next !== "string") return;
  const db = createAdminClient();
  await db
    .from("tribes")
    .update({ is_featured: next === "true" })
    .eq("tribe_id", id);
  revalidatePath("/tribes");
}

async function toggleSuspendedAction(formData: FormData) {
  "use server";
  const id = formData.get("id");
  const next = formData.get("next");
  if (typeof id !== "string" || typeof next !== "string") return;
  const db = createAdminClient();
  await db
    .from("tribes")
    .update({ is_suspended: next === "true" })
    .eq("tribe_id", id);
  revalidatePath("/tribes");
}

export default async function AdminTribesPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; category?: string; only?: string }>;
}) {
  const params = await searchParams;
  const q = params.q?.trim() ?? "";
  const category = params.category ?? "";
  const only = params.only ?? ""; // featured | suspended | private

  const db = createAdminClient();
  let query = db
    .from("tribes")
    .select(
      "tribe_id, name, slug, category, description, member_count, is_private, is_featured, is_suspended, created_at, keeper_id, users:keeper_id(anonymous_pseudonym, is_verified)"
    )
    .order("member_count", { ascending: false })
    .limit(200);
  if (q) query = query.ilike("name", `%${q}%`);
  if (category) query = query.eq("category", category);
  if (only === "featured") query = query.eq("is_featured", true);
  if (only === "suspended") query = query.eq("is_suspended", true);
  if (only === "private") query = query.eq("is_private", true);
  const { data, error } = await query;
  const rows = (data ?? []) as unknown as Row[];

  return (
    <div className="flex flex-col gap-6 max-w-6xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Tribes</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          All tribes on the platform. Feature ones worth surfacing, suspend
          ones that need attention.
        </p>
      </div>

      <form className="flex gap-3 flex-wrap" method="get">
        <input
          name="q"
          placeholder="Search tribe name…"
          defaultValue={q}
          className="rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm w-72"
        />
        <select
          name="category"
          defaultValue={category}
          className="rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm"
        >
          <option value="">All categories</option>
          <option value="campus">Campus</option>
          <option value="city">City</option>
          <option value="interest_group">Interest</option>
          <option value="hobby">Hobby</option>
          <option value="support">Support</option>
          <option value="venting">Venting</option>
        </select>
        <select
          name="only"
          defaultValue={only}
          className="rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm"
        >
          <option value="">All tribes</option>
          <option value="featured">Featured only</option>
          <option value="suspended">Suspended only</option>
          <option value="private">Private only</option>
        </select>
        <button className="btn-secondary" type="submit">
          Apply
        </button>
        {(q || category || only) && (
          <a href="/tribes" className="btn-secondary">
            Clear
          </a>
        )}
      </form>

      {error && (
        <div className="card p-4 border-danger/30 text-danger">
          Could not load tribes: {error.message}
        </div>
      )}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="text-[11px] font-bold uppercase tracking-widest text-burgundy/55 bg-cardBlush/60">
            <tr>
              <th className="text-left px-4 py-3">Tribe</th>
              <th className="text-left px-4 py-3">Keeper</th>
              <th className="text-left px-4 py-3">Category</th>
              <th className="text-right px-4 py-3">Members</th>
              <th className="text-left px-4 py-3">Flags</th>
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
                  No tribes match the current filter.
                </td>
              </tr>
            )}
            {rows.map((t) => (
              <tr
                key={t.tribe_id}
                className="border-t border-mauve/20 hover:bg-cardBlush/40 align-top"
              >
                <td className="px-4 py-3">
                  <p className="font-semibold text-burgundy">{t.name}</p>
                  <p className="text-[11px] text-burgundy/55 mt-1 max-w-[280px] line-clamp-2">
                    {t.description ?? <span className="italic">No description.</span>}
                  </p>
                </td>
                <td className="px-4 py-3 text-burgundy/80">
                  {t.users?.anonymous_pseudonym ? (
                    <span>
                      @{t.users.anonymous_pseudonym}
                      {t.users.is_verified && (
                        <span className="text-berry ml-1" title="Verified">
                          ✓
                        </span>
                      )}
                    </span>
                  ) : (
                    <span className="italic text-burgundy/40">Unknown</span>
                  )}
                </td>
                <td className="px-4 py-3 text-burgundy/80">{t.category}</td>
                <td className="px-4 py-3 text-right text-burgundy/80">
                  {t.member_count}
                </td>
                <td className="px-4 py-3">
                  <div className="flex flex-wrap gap-1">
                    {t.is_featured && (
                      <span className="pill bg-ok/15 text-ok">Featured</span>
                    )}
                    {t.is_suspended && (
                      <span className="pill bg-danger/15 text-danger">
                        Suspended
                      </span>
                    )}
                    {t.is_private && (
                      <span className="pill bg-mauve/25 text-burgundy/70">
                        Private
                      </span>
                    )}
                    {!t.is_featured && !t.is_suspended && !t.is_private && (
                      <span className="text-[11px] text-burgundy/40 italic">
                        none
                      </span>
                    )}
                  </div>
                </td>
                <td className="px-4 py-3">
                  <div className="flex gap-2 justify-end flex-wrap">
                    <form action={toggleFeaturedAction}>
                      <input type="hidden" name="id" value={t.tribe_id} />
                      <input
                        type="hidden"
                        name="next"
                        value={(!t.is_featured).toString()}
                      />
                      <button className="btn-secondary" type="submit">
                        {t.is_featured ? "Unfeature" : "Feature"}
                      </button>
                    </form>
                    <form action={toggleSuspendedAction}>
                      <input type="hidden" name="id" value={t.tribe_id} />
                      <input
                        type="hidden"
                        name="next"
                        value={(!t.is_suspended).toString()}
                      />
                      <button className="btn-secondary" type="submit">
                        {t.is_suspended ? "Lift suspension" : "Suspend"}
                      </button>
                    </form>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-burgundy/55">
        Suspended tribes are hidden from the public directory next time the
        directory query runs. Members keep access to their existing data.
      </p>
    </div>
  );
}
