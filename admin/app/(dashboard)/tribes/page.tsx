import Link from "next/link";
import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import {
  ChevronRight,
  Search,
  Sparkles,
  Users2,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Row = {
  tribe_id: string;
  name: string;
  slug: string;
  description: string | null;
  category: string;
  is_private: boolean;
  is_featured: boolean;
  member_count: number;
  keeper_id: string | null;
  created_at: string;
};

async function toggleFeaturedAction(formData: FormData) {
  "use server";
  const id = String(formData.get("tribe_id") ?? "");
  const featured = String(formData.get("featured") ?? "") === "true";
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_set_tribe_featured", {
    p_tribe: id,
    p_featured: featured,
    p_reason: reason || null,
  });
  revalidatePath("/tribes");
}

export default async function TribesPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; category?: string; featured?: string }>;
}) {
  const params = await searchParams;
  const q = params.q?.trim() ?? "";
  const category = params.category ?? "";
  const featuredFilter = params.featured ?? "";

  const db = createAdminClient();
  let query = db
    .from("tribes")
    .select(
      "tribe_id, name, slug, description, category, is_private, is_featured, member_count, keeper_id, created_at"
    )
    .order("member_count", { ascending: false })
    .limit(200);
  if (q) query = query.ilike("name", `%${q}%`);
  if (category) query = query.eq("category", category);
  if (featuredFilter === "true") query = query.eq("is_featured", true);
  if (featuredFilter === "false") query = query.eq("is_featured", false);
  const { data, error } = await query;
  const rows = (data ?? []) as Row[];

  // Activity signal: posts per tribe in last 7d
  const since = new Date(Date.now() - 7 * 86400 * 1000).toISOString();
  const { data: weeklyPosts } = await db
    .from("posts")
    .select("tribe_id")
    .gte("created_at", since)
    .not("tribe_id", "is", null)
    .is("deleted_at", null);
  const activity = new Map<string, number>();
  for (const p of (weeklyPosts ?? []) as { tribe_id: string }[]) {
    activity.set(p.tribe_id, (activity.get(p.tribe_id) ?? 0) + 1);
  }

  const categories = Array.from(
    new Set(
      (rows.map((r) => r.category).filter(Boolean) as string[]).concat([
        "healing",
        "academic",
        "career",
        "creative",
        "lgbtq",
        "neurodivergent",
        "relationships",
      ])
    )
  );

  return (
    <div className="flex flex-col gap-6 max-w-[1300px]">
      <PageHeader
        eyebrow="Manage"
        title="Tribes"
        subtitle="Communities on Venttly. Inspect health, feature growth, intervene on problems."
        actions={
          <span className="text-xs text-ink-muted">
            {rows.length} listed · {rows.filter((r) => r.is_featured).length} featured
          </span>
        }
      />

      <Card padded>
        <form className="flex flex-wrap gap-3 items-end" method="get">
          <div className="flex-1 min-w-[220px]">
            <label className="h-eyebrow block mb-1">Name</label>
            <div className="relative">
              <Search
                size={14}
                className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted"
              />
              <input
                name="q"
                placeholder="Search tribe name…"
                defaultValue={q}
                className="input pl-9"
              />
            </div>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Category</label>
            <select name="category" defaultValue={category} className="select">
              <option value="">All</option>
              {categories.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Featured</label>
            <select name="featured" defaultValue={featuredFilter} className="select">
              <option value="">Either</option>
              <option value="true">Featured</option>
              <option value="false">Not featured</option>
            </select>
          </div>
          <button className="btn-secondary" type="submit">
            Apply
          </button>
          {(q || category || featuredFilter) && (
            <a href="/tribes" className="btn-ghost">
              Clear
            </a>
          )}
        </form>
      </Card>

      {error && (
        <Card padded>
          <p className="text-sm text-danger">
            Could not load tribes: {error.message}
          </p>
        </Card>
      )}

      {rows.length === 0 ? (
        <Card padded>
          <EmptyState
            icon={<Users2 size={32} />}
            title="No tribes match the filter."
          />
        </Card>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
          {rows.map((t) => {
            const weekly = activity.get(t.tribe_id) ?? 0;
            return (
              <article
                key={t.tribe_id}
                className="surface p-5 flex flex-col gap-3"
              >
                <header className="flex items-start gap-3">
                  <div className="h-10 w-10 rounded-xl bg-berry/12 text-berry flex items-center justify-center text-base font-extrabold">
                    {t.name.slice(0, 2).toUpperCase()}
                  </div>
                  <div className="flex-1 min-w-0">
                    <Link
                      href={`/tribes/${t.tribe_id}`}
                      className="font-extrabold text-burgundy hover:text-berry block truncate"
                    >
                      {t.name}
                    </Link>
                    <p className="text-xs text-ink-muted">
                      /{t.slug} · {t.category}
                    </p>
                  </div>
                  <div className="flex flex-col gap-1 items-end">
                    {t.is_featured && (
                      <Badge tone="info" icon={<Sparkles size={11} />}>
                        featured
                      </Badge>
                    )}
                    {t.is_private && <Badge tone="warn">private</Badge>}
                  </div>
                </header>
                {t.description && (
                  <p className="text-xs text-ink-muted line-clamp-2">
                    {t.description}
                  </p>
                )}
                <div className="grid grid-cols-3 gap-2 pt-3 border-t border-line">
                  <Metric label="Members" value={t.member_count} />
                  <Metric
                    label="Posts · 7d"
                    value={weekly}
                    tone={weekly === 0 ? "warn" : "neutral"}
                  />
                  <Metric
                    label="Age"
                    value={`${Math.max(
                      1,
                      Math.round(
                        (Date.now() - new Date(t.created_at).getTime()) /
                          86400000
                      )
                    )}d`}
                  />
                </div>
                <div className="flex gap-2 mt-1">
                  <form action={toggleFeaturedAction}>
                    <input type="hidden" name="tribe_id" value={t.tribe_id} />
                    <input
                      type="hidden"
                      name="featured"
                      value={t.is_featured ? "false" : "true"}
                    />
                    <button className="btn-ghost" type="submit">
                      {t.is_featured ? "Unfeature" : "Feature"}
                    </button>
                  </form>
                  <Link
                    href={`/tribes/${t.tribe_id}`}
                    className="btn-ghost ml-auto"
                  >
                    Open <ChevronRight size={13} />
                  </Link>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </div>
  );
}

function Metric({
  label,
  value,
  tone = "neutral",
}: {
  label: string;
  value: number | string;
  tone?: "neutral" | "warn";
}) {
  return (
    <div>
      <p className="h-eyebrow">{label}</p>
      <p
        className={`tabular text-base font-extrabold ${
          tone === "warn" ? "text-warn" : "text-burgundy"
        }`}
      >
        {typeof value === "number" ? value.toLocaleString() : value}
      </p>
    </div>
  );
}
