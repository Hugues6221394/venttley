import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import {
  CapabilityNotice,
  Pagination,
  positivePage,
} from "@/components/ui/operations";
import { FileText, Search } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const PAGE_SIZE = 50;
const TYPES = ["post", "story", "comment", "whisper"] as const;
const STATUSES = ["live", "removed", "quarantined", "all"] as const;
type ContentType = (typeof TYPES)[number];

type ContentRow = {
  id: string;
  kind: ContentType;
  authorId: string;
  body: string;
  createdAt: string;
  deletedAt: string | null;
  mediaStatus: string | null;
  reports: number | null;
};

type Person = {
  user_id: string;
  display_name: string;
  anonymous_pseudonym: string;
};

function contentTone(row: ContentRow): Tone {
  if (row.deletedAt) return "danger";
  if (row.mediaStatus && row.mediaStatus !== "clean" && row.mediaStatus !== "approved") {
    return "warn";
  }
  return "ok";
}

function contentStatus(row: ContentRow): string {
  if (row.deletedAt) return "removed";
  if (row.mediaStatus && row.mediaStatus !== "clean" && row.mediaStatus !== "approved") {
    return row.mediaStatus;
  }
  return "live";
}

export default async function ContentPage({
  searchParams,
}: {
  searchParams: Promise<{
    type?: string;
    status?: string;
    q?: string;
    page?: string;
  }>;
}) {
  const params = await searchParams;
  const kind = (TYPES as readonly string[]).includes(params.type ?? "")
    ? (params.type as ContentType)
    : "post";
  const status = (STATUSES as readonly string[]).includes(params.status ?? "")
    ? (params.status as (typeof STATUSES)[number])
    : "live";
  const q = (params.q ?? "").trim().slice(0, 100);
  const page = positivePage(params.page);
  const from = (page - 1) * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;
  const db = await createAdminClient();

  let rows: ContentRow[] = [];
  let total = 0;
  let error: string | null = null;

  if (kind === "post" || kind === "story") {
    let query = db
      .from("posts")
      .select(
        "post_id, author_id, content, created_at, deleted_at, media_status, is_story, likes_count, comments_count",
        { count: "exact" },
      )
      .eq("is_story", kind === "story")
      .order("created_at", { ascending: false });
    if (status === "live") query = query.is("deleted_at", null);
    if (status === "removed") query = query.not("deleted_at", "is", null);
    if (status === "quarantined") {
      query = query.in("media_status", ["pending", "sensitive", "blocked"]);
    }
    if (q) query = query.ilike("content", `%${q}%`);
    const result = await query.range(from, to);
    error = result.error?.message ?? null;
    total = result.count ?? 0;
    rows = (result.data ?? []).map((row) => ({
      id: row.post_id,
      kind,
      authorId: row.author_id,
      body: row.content,
      createdAt: row.created_at,
      deletedAt: row.deleted_at,
      mediaStatus: row.media_status,
      reports: null,
    }));
  } else if (kind === "comment") {
    let query = db
      .from("posts_comments")
      .select("comment_id, author_id, content, created_at, deleted_at, likes_count", {
        count: "exact",
      })
      .order("created_at", { ascending: false });
    if (status === "live" || status === "quarantined") query = query.is("deleted_at", null);
    if (status === "removed") query = query.not("deleted_at", "is", null);
    if (q) query = query.ilike("content", `%${q}%`);
    const result = await query.range(from, to);
    error = result.error?.message ?? null;
    total = result.count ?? 0;
    rows = (result.data ?? []).map((row) => ({
      id: row.comment_id,
      kind,
      authorId: row.author_id,
      body: row.content,
      createdAt: row.created_at,
      deletedAt: row.deleted_at,
      mediaStatus: status === "quarantined" ? "not supported" : null,
      reports: null,
    }));
  } else {
    let query = db
      .from("whispers")
      .select(
        "whisper_id, author_id, title, description, created_at, deleted_at, media_status, likes_count, comments_count",
        { count: "exact" },
      )
      .order("created_at", { ascending: false });
    if (status === "live") query = query.is("deleted_at", null);
    if (status === "removed") query = query.not("deleted_at", "is", null);
    if (status === "quarantined") {
      query = query.in("media_status", ["pending", "sensitive", "blocked"]);
    }
    if (q) query = query.or(`title.ilike.%${q}%,description.ilike.%${q}%`);
    const result = await query.range(from, to);
    error = result.error?.message ?? null;
    total = result.count ?? 0;
    rows = (result.data ?? []).map((row) => ({
      id: row.whisper_id,
      kind,
      authorId: row.author_id,
      body: [row.title, row.description].filter(Boolean).join("\n"),
      createdAt: row.created_at,
      deletedAt: row.deleted_at,
      mediaStatus: row.media_status,
      reports: null,
    }));
  }

  const authorIds = [...new Set(rows.map((row) => row.authorId))];
  const authorsResult =
    authorIds.length > 0
      ? await db
          .from("users")
          .select("user_id, display_name, anonymous_pseudonym")
          .in("user_id", authorIds)
      : { data: [], error: null };
  const authors = new Map(
    ((authorsResult.data ?? []) as Person[]).map((person) => [person.user_id, person]),
  );
  error ??= authorsResult.error?.message ?? null;

  return (
    <div className="flex max-w-[1300px] flex-col gap-6">
      <PageHeader
        eyebrow="Operate"
        title="Content explorer"
        subtitle="Find and inspect Vents, Stories, comments, and Whispers without loading an unbounded feed. Display names are primary; immutable IDs remain available for investigations."
        actions={
          <Link href="/moderation?tab=cases" className="btn-secondary">
            Open case queue
          </Link>
        }
      />

      <Card>
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label className="h-eyebrow mb-1 block">Content type</label>
            <select name="type" defaultValue={kind} className="select">
              {TYPES.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="h-eyebrow mb-1 block">State</label>
            <select name="status" defaultValue={status} className="select">
              {STATUSES.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </select>
          </div>
          <div className="min-w-[240px] flex-1">
            <label className="h-eyebrow mb-1 block">Text contains</label>
            <div className="relative">
              <Search
                size={14}
                className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted"
              />
              <input
                name="q"
                defaultValue={q}
                maxLength={100}
                className="input pl-9"
                placeholder="Search this content type"
              />
            </div>
          </div>
          <button type="submit" className="btn-secondary">
            Apply
          </button>
          {(q || status !== "live" || kind !== "post") && (
            <Link href="/content" className="btn-ghost">
              Clear
            </Link>
          )}
        </form>
      </Card>

      {error && (
        <ErrorPanel
          title="Content results are incomplete"
          detail={error}
          hint="No empty-state claim is made while a source query is failing. Retry after checking the Data API and database health."
        />
      )}

      {!error && rows.length === 0 ? (
        <Card>
          <EmptyState
            icon={<FileText size={32} />}
            title="No content matches this filter."
            hint="Try a different type, state, or search phrase."
          />
        </Card>
      ) : (
        rows.length > 0 && (
          <Card
            title={`${kind[0].toUpperCase()}${kind.slice(1)} results`}
            hint={`${total.toLocaleString()} matching records`}
            padded={false}
          >
            <ul className="divide-y divide-line">
              {rows.map((row) => {
                const person = authors.get(row.authorId);
                return (
                  <li key={row.id} className="px-5 py-4">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge>{row.kind}</Badge>
                      <Badge tone={contentTone(row)}>{contentStatus(row)}</Badge>
                      <Link
                        href={`/users/${row.authorId}`}
                        className="text-sm font-bold text-burgundy hover:text-berry"
                      >
                        {person?.display_name || "Unknown member"}
                      </Link>
                      {person && (
                        <span className="text-xs text-ink-muted">
                          @{person.anonymous_pseudonym}
                        </span>
                      )}
                      <time className="ml-auto text-[11px] text-ink-muted">
                        {new Date(row.createdAt).toLocaleString()}
                      </time>
                    </div>
                    <p className="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-burgundy">
                      {row.body
                        ? row.body.length > 700
                          ? `${row.body.slice(0, 700).trimEnd()}…`
                          : row.body
                        : "No text. This item may contain audio or image media only."}
                    </p>
                    <p className="mt-2 select-all font-mono text-[10px] text-ink-muted">
                      {row.id}
                    </p>
                  </li>
                );
              })}
            </ul>
            <Pagination
              basePath="/content"
              page={page}
              pageSize={PAGE_SIZE}
              total={total}
              params={{ type: kind, status, q }}
            />
          </Card>
        )
      )}

      <CapabilityNotice title="Destructive controls are intentionally case-bound">
        This explorer does not perform direct deletes. Removal, suspension, and
        evidence access belong to a moderation case so the reason, preserved
        evidence, appeal path, and actor are recorded together. In the backend
        hardening phase, report ingress for Stories, profiles, questions, and
        standalone media must be unified before more action buttons are added.
      </CapabilityNotice>
    </div>
  );
}
