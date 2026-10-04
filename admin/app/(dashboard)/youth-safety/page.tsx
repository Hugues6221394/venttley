import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning, Pagination, positivePage } from "@/components/ui/operations";
import { ShieldCheck } from "@/components/ui/icons";

export const dynamic = "force-dynamic";
const PAGE_SIZE = 50;

type UnknownAgeAccount = {
  user_id: string;
  display_name: string;
  anonymous_pseudonym: string;
  account_status: string;
  created_at: string;
  last_seen_at: string | null;
};

export default async function YouthSafetyPage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  const { page: rawPage } = await searchParams;
  const page = positivePage(rawPage);
  const from = (page - 1) * PAGE_SIZE;
  const year = new Date().getUTCFullYear();
  const db = await createAdminClient();
  const [unknown, likelyMinor, belowMinimum, activeUnknown, rowsResult] = await Promise.all([
    db.from("users").select("user_id", { count: "exact", head: true }).is("birth_year", null),
    db.from("users").select("user_id", { count: "exact", head: true }).gte("birth_year", year - 17),
    db.from("users").select("user_id", { count: "exact", head: true }).gte("birth_year", year - 12),
    db.from("users").select("user_id", { count: "exact", head: true }).is("birth_year", null).eq("account_status", "active").is("deactivated_at", null),
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, created_at, last_seen_at", { count: "exact" }).is("birth_year", null).order("created_at", { ascending: true }).range(from, from + PAGE_SIZE - 1),
  ]);
  const errors = [unknown, likelyMinor, belowMinimum, activeUnknown, rowsResult].flatMap((result) => result.error ? [result.error.message] : []);
  const rows = (rowsResult.data ?? []) as UnknownAgeAccount[];

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Youth safety" subtitle="Age-completion and minimum-age control without displaying birth years, recovery contacts, locations, or authored content." />
      <DataWarning caveat title="Birth year is not age assurance">
        The counts below are conservative year-based bands. They cannot prove
        identity or exact age and must not be represented as verified age.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Youth-safety posture is incomplete" detail={errors.join("\n")} />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Unknown age" value={unknown.count} tone={(unknown.count ?? 0) > 0 ? "warn" : "ok"} />
        <Metric label="Active unknown-age" value={activeUnknown.count} tone={(activeUnknown.count ?? 0) > 0 ? "danger" : "ok"} />
        <Metric label="Possible minors" value={likelyMinor.count} tone="info" />
        <Metric label="Potentially below 13" value={belowMinimum.count} tone={(belowMinimum.count ?? 0) > 0 ? "danger" : "ok"} />
      </div>
      <Card title="Unknown-age accounts" hint="Oldest unresolved accounts first" padded={false}>
        {rows.length === 0 ? (
          <EmptyState icon={<ShieldCheck size={32} />} title="No unknown-age accounts returned." hint={errors.length ? "A source failure prevents a definitive conclusion." : "Every account currently has a birth-year value."} />
        ) : (
          <>
            <ul className="divide-y divide-line">
              {rows.map((row) => (
                <li key={row.user_id} className="flex flex-wrap items-center gap-3 px-5 py-3">
                  <div className="min-w-0 flex-1">
                    <Link href={`/users/${row.user_id}`} className="font-bold text-burgundy hover:text-berry">{row.display_name}</Link>
                    <p className="text-xs text-ink-muted">@{row.anonymous_pseudonym} · joined {new Date(row.created_at).toLocaleDateString()}</p>
                  </div>
                  <Badge tone={row.account_status === "active" ? "danger" : "warn"}>{row.account_status}</Badge>
                  <span className="text-[11px] text-ink-muted">{row.last_seen_at ? `seen ${new Date(row.last_seen_at).toLocaleString()}` : "never seen"}</span>
                </li>
              ))}
            </ul>
            <Pagination basePath="/youth-safety" page={page} pageSize={PAGE_SIZE} total={rowsResult.count ?? 0} />
          </>
        )}
      </Card>
      <CapabilityNotice title="Age completion and interaction safeguards need backend completion">
        The server currently fails unknown-age writers safely, but the console
        still needs an audited remediation workflow, age-policy versioning,
        adult/minor interaction signals, regional thresholds, and appeal paths.
        No administrator may directly edit a member&apos;s birth year here.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "ok" | "warn" | "danger" | "info" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-2xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone}</Badge></div></Card>;
}
