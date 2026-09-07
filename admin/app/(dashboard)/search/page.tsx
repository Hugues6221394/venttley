import Link from "next/link";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Search, ShieldAlert } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Hit = {
  kind: string;
  id: string;
  title: string | null;
  subtitle: string | null;
  href: string;
  occurred_at: string | null;
};

const KIND_LABEL: Record<string, string> = {
  user: "Member",
  post: "Post",
  tribe: "Tribe",
  case: "Case",
  report: "Report",
  appeal: "Appeal",
  csam_incident: "CSAM",
};

const KIND_TONE: Record<string, Tone> = {
  user: "info",
  post: "neutral",
  tribe: "neutral",
  case: "warn",
  report: "warn",
  appeal: "warn",
  csam_incident: "crisis",
};

export default async function SearchPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const query = (q ?? "").trim();

  let hits: Hit[] = [];
  let error: string | null = null;

  if (query.length >= 4) {
    try {
      hits = (await rpc<Hit[]>("admin_global_search", {
        p_query: query,
        p_limit: 8,
      })) ?? [];
    } catch (e) {
      // The RPC refuses short queries and non-staff callers. Show its reason
      // rather than an error boundary — this is a search box, and a rejected
      // query is a normal outcome.
      error = e instanceof Error ? e.message.replace(/^admin_global_search: /, "") : "Search failed.";
    }
  }

  const grouped = hits.reduce<Record<string, Hit[]>>((acc, h) => {
    (acc[h.kind] ??= []).push(h);
    return acc;
  }, {});

  return (
    <div className="flex flex-col gap-6 max-w-[1000px]">
      <PageHeader
        eyebrow="Find"
        title={query ? `Results for “${query}”` : "Search"}
        subtitle="Members, posts, Tribes, and any ID you paste — cases, reports, appeals. Scoped to what your role may open, capped, and audited: each search records who looked for what."
      />

      {query.length > 0 && query.length < 4 && (
        <Card padded>
          <p className="text-sm text-warn">
            Type at least four characters. Shorter queries would let the box be
            used to enumerate members a letter at a time.
          </p>
        </Card>
      )}

      {error && (
        <Card padded>
          <p className="text-sm text-danger">{error}</p>
        </Card>
      )}

      {query.length >= 4 && !error && hits.length === 0 && (
        <Card padded={false}>
          <div className="px-5 py-12">
            <EmptyState
              icon={<Search size={32} />}
              title="Nothing matched."
              hint="Pseudonyms match from the start; post text matches anywhere. IDs must be exact — they are never matched by prefix, so they cannot be guessed a character at a time."
            />
          </div>
        </Card>
      )}

      {Object.entries(grouped).map(([kind, rows]) => (
        <Card
          key={kind}
          title={KIND_LABEL[kind] ?? kind}
          hint={`${rows.length} result${rows.length === 1 ? "" : "s"}`}
          padded={false}
        >
          <ul className="divide-y divide-line">
            {rows.map((h) => (
              <li key={`${h.kind}-${h.id}`}>
                <Link
                  href={h.href}
                  className="flex items-start gap-3 px-5 py-3 hover:bg-canvas transition"
                >
                  <Badge tone={KIND_TONE[kind] ?? "neutral"}>
                    {kind === "csam_incident" ? (
                      <ShieldAlert size={11} />
                    ) : null}
                    {KIND_LABEL[kind] ?? kind}
                  </Badge>
                  <div className="min-w-0 flex-1">
                    <p className="text-sm text-burgundy break-words">
                      {h.title || "(no preview)"}
                    </p>
                    {h.subtitle && (
                      <p className="text-[11px] text-ink-muted mt-0.5">
                        {h.subtitle}
                      </p>
                    )}
                    <p className="font-mono text-[10px] text-ink-muted mt-0.5 select-all">
                      {h.id}
                    </p>
                  </div>
                  {h.occurred_at && (
                    <span className="text-[11px] text-ink-muted whitespace-nowrap">
                      {new Date(h.occurred_at).toLocaleDateString()}
                    </span>
                  )}
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      ))}

      {query.length >= 4 && hits.length > 0 && (
        <p className="text-[11px] text-ink-muted">
          Results are capped per kind. Private message bodies are deliberately
          not searchable — they are reachable only through a case, behind a
          separate accessor that logs each read.
        </p>
      )}
    </div>
  );
}
