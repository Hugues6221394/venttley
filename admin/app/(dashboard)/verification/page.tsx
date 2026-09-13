import Link from "next/link";
import { revalidatePath } from "next/cache";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { CheckCircle2, XCircle } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

/**
 * The review queue.
 *
 * Previously this listed `status = 'pending'` straight off the table and
 * offered Approve / Deny. It could not show a reviewer the evidence somebody
 * submitted, could not tell them a colleague already had the case open, could
 * not ask the applicant a question, and could not take a check back once
 * granted.
 *
 * Everything here now goes through the admin_* RPCs from
 * 20261014090000, which are the authorization boundary: each one re-checks
 * `is_staff(auth.uid(), ARRAY['super_admin'])` in the database and writes both
 * the per-request timeline and the admin_log row in the same transaction.
 * Hiding a button in this page is a courtesy, not a control.
 */

type QueueRow = {
  request_id: string;
  user_id: string;
  pseudonym: string;
  status: string;
  category: string | null;
  note: string | null;
  links: string[] | null;
  evidence_count: number;
  internal_note: string | null;
  info_request: string | null;
  applicant_response: string | null;
  claimed_by_pseudonym: string | null;
  reviewed_by_pseudonym: string | null;
  review_reason: string | null;
  created_at: string;
  reviewed_at: string | null;
  is_verified: boolean;
  connections_count: number | null;
  karma_points: number | null;
};

async function review(formData: FormData) {
  "use server";
  await rpc("admin_review_verification", {
    p_request: String(formData.get("request_id") ?? ""),
    p_approve: String(formData.get("approve") ?? "") === "true",
    p_reason: String(formData.get("reason") ?? "") || null,
  });
  revalidatePath("/verification");
}

async function claim(formData: FormData) {
  "use server";
  await rpc("admin_claim_verification", {
    p_request: String(formData.get("request_id") ?? ""),
  });
  revalidatePath("/verification");
}

async function askForInfo(formData: FormData) {
  "use server";
  await rpc("admin_request_verification_info", {
    p_request: String(formData.get("request_id") ?? ""),
    p_message: String(formData.get("message") ?? ""),
  });
  revalidatePath("/verification");
}

async function saveNote(formData: FormData) {
  "use server";
  await rpc("admin_set_verification_note", {
    p_request: String(formData.get("request_id") ?? ""),
    p_note: String(formData.get("internal_note") ?? ""),
  });
  revalidatePath("/verification");
}

async function revoke(formData: FormData) {
  "use server";
  await rpc("admin_revoke_verification", {
    p_user: String(formData.get("user_id") ?? ""),
    p_reason: String(formData.get("reason") ?? ""),
  });
  revalidatePath("/verification");
}

const TABS = [
  { key: "open", label: "Open" },
  { key: "pending", label: "Unclaimed" },
  { key: "under_review", label: "Being reviewed" },
  { key: "more_info", label: "Waiting on applicant" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
  { key: "revoked", label: "Revoked" },
  { key: "all", label: "Everything" },
] as const;

// The console's Tone union, not invented names — "good"/"bad" are not in it
// and tsc rejects them.
function toneFor(status: string): Tone {
  if (status === "approved") return "ok";
  if (status === "rejected" || status === "revoked") return "danger";
  if (status === "more_info") return "warn";
  return "neutral";
}

export default async function VerificationQueuePage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; q?: string }>;
}) {
  const params = await searchParams;
  const tab = params.status ?? "open";
  const search = params.q ?? "";

  // "Open" is the default and is not a single stored status, so it is fetched
  // as everything and narrowed here — a reviewer arriving at this page wants
  // the work, not a status filter they have to assemble.
  const rows = (await rpc<QueueRow[]>("admin_verification_queue", {
    p_status: tab === "open" ? "all" : tab,
    p_search: search || null,
    p_limit: 200,
  })) ?? [];

  const visible =
    tab === "open"
      ? rows.filter((r) =>
          ["pending", "under_review", "more_info"].includes(r.status)
        )
      : rows;

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Manage"
        title="Verification queue"
        subtitle="Applications for the verified check. Auto-verification is reserved for stunning reach (100K connections / 1M hugs), so most verified members come through here. super_admin only."
      />

      <div className="flex flex-wrap items-center gap-2">
        {TABS.map((t) => (
          <Link
            key={t.key}
            href={`/verification?status=${t.key}${
              search ? `&q=${encodeURIComponent(search)}` : ""
            }`}
            className={
              tab === t.key
                ? "btn-primary text-xs"
                : "btn-secondary text-xs"
            }
          >
            {t.label}
          </Link>
        ))}

        {/* GET, so a filtered queue is a shareable URL a reviewer can hand to
            a colleague. */}
        <form action="/verification" method="GET" className="ml-auto flex gap-2">
          <input type="hidden" name="status" value={tab} />
          <input
            type="text"
            name="q"
            defaultValue={search}
            placeholder="search handle or display name"
            className="input min-w-[220px]"
          />
          <button type="submit" className="btn-secondary text-xs">
            Search
          </button>
        </form>
      </div>

      <Card title={`${visible.length} application(s)`} padded={false}>
        {visible.length === 0 ? (
          <div className="px-5 py-12 text-sm text-ink-muted italic">
            Nothing here.
          </div>
        ) : (
          <ul className="divide-y divide-line">
            {visible.map((r) => (
              <li key={r.request_id} className="px-5 py-4 flex flex-col gap-3">
                <div className="flex flex-wrap items-center gap-3">
                  <Link
                    href={`/users/${r.user_id}`}
                    className="font-bold text-burgundy hover:text-berry"
                  >
                    @{r.pseudonym}
                  </Link>
                  <Badge tone={toneFor(r.status)}>{r.status}</Badge>
                  {r.category && <Badge tone="neutral">{r.category}</Badge>}
                  <Badge tone="neutral">
                    {(r.connections_count ?? 0).toLocaleString()} connections
                  </Badge>
                  {/* Who has it, so two reviewers do not decide the same case. */}
                  {r.claimed_by_pseudonym && r.status === "under_review" && (
                    <span className="text-[11px] text-ink-muted">
                      held by @{r.claimed_by_pseudonym}
                    </span>
                  )}
                  {r.reviewed_by_pseudonym && r.reviewed_at && (
                    <span className="text-[11px] text-ink-muted">
                      decided by @{r.reviewed_by_pseudonym} on{" "}
                      {new Date(r.reviewed_at).toLocaleDateString()}
                    </span>
                  )}
                  <span className="text-[11px] text-ink-muted ml-auto">
                    applied {new Date(r.created_at).toLocaleString()}
                  </span>
                </div>

                {r.note && (
                  <p className="text-sm text-burgundy bg-canvas/60 rounded-xl px-4 py-3 italic">
                    “{r.note}”
                  </p>
                )}

                {r.links && r.links.length > 0 && (
                  <ul className="flex flex-wrap gap-3 text-xs">
                    {r.links.map((l) => (
                      <li key={l}>
                        {/* noreferrer so an applicant's site cannot see that
                            the referrer was the admin console. */}
                        <a
                          href={l}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="text-berry underline break-all"
                        >
                          {l}
                        </a>
                      </li>
                    ))}
                  </ul>
                )}

                {/* Only the count. Evidence can be identity documents, so it
                    is opened one application at a time on the user page rather
                    than rendered into a list response. */}
                {r.evidence_count > 0 && (
                  <p className="text-xs text-ink-muted">
                    {r.evidence_count} private evidence item(s) submitted —
                    open the applicant to read them.
                  </p>
                )}

                {r.info_request && (
                  <p className="text-xs text-ink-muted">
                    <strong>Asked:</strong> {r.info_request}
                  </p>
                )}
                {r.applicant_response && (
                  <p className="text-sm text-burgundy bg-canvas/60 rounded-xl px-4 py-3">
                    <strong className="text-xs uppercase tracking-wide">
                      Their answer
                    </strong>
                    <br />
                    {r.applicant_response}
                  </p>
                )}
                {r.review_reason && (
                  <p className="text-xs text-ink-muted">
                    <strong>Reason given:</strong> {r.review_reason}
                  </p>
                )}

                {["pending", "under_review", "more_info"].includes(
                  r.status
                ) && (
                  <>
                    {r.status === "pending" && (
                      <form action={claim}>
                        <input
                          type="hidden"
                          name="request_id"
                          value={r.request_id}
                        />
                        <button type="submit" className="btn-secondary text-xs">
                          Claim
                        </button>
                      </form>
                    )}

                    <form
                      action={review}
                      className="flex flex-wrap items-center gap-2"
                    >
                      <input
                        type="hidden"
                        name="request_id"
                        value={r.request_id}
                      />
                      <input
                        type="text"
                        name="reason"
                        placeholder="reason (shown to the applicant)"
                        className="input flex-1 min-w-[200px]"
                      />
                      <button
                        type="submit"
                        name="approve"
                        value="true"
                        className="btn-secondary text-green-700 border-green-300 hover:bg-green-50 inline-flex items-center gap-1"
                      >
                        <CheckCircle2 size={14} /> Approve
                      </button>
                      <button
                        type="submit"
                        name="approve"
                        value="false"
                        className="btn-secondary text-red-600 border-red-300 hover:bg-red-50 inline-flex items-center gap-1"
                      >
                        <XCircle size={14} /> Reject
                      </button>
                    </form>

                    <form
                      action={askForInfo}
                      className="flex flex-wrap items-center gap-2"
                    >
                      <input
                        type="hidden"
                        name="request_id"
                        value={r.request_id}
                      />
                      <input
                        type="text"
                        name="message"
                        required
                        placeholder="what do you need from them?"
                        className="input flex-1 min-w-[200px]"
                      />
                      <button type="submit" className="btn-secondary text-xs">
                        Ask for more
                      </button>
                    </form>
                  </>
                )}

                {/* Revoke takes a user, not a request: a check can also have
                    come from the automatic reach sweep with no application
                    behind it, and it must be removable in that case too. */}
                {r.is_verified && (
                  <form
                    action={revoke}
                    className="flex flex-wrap items-center gap-2"
                  >
                    <input type="hidden" name="user_id" value={r.user_id} />
                    <input
                      type="text"
                      name="reason"
                      required
                      placeholder="why is the check being removed?"
                      className="input flex-1 min-w-[200px]"
                    />
                    <button
                      type="submit"
                      className="btn-secondary text-red-600 border-red-300 hover:bg-red-50 text-xs"
                    >
                      Revoke verification
                    </button>
                  </form>
                )}

                {/* Staff-only scratch space. Never returned to the applicant
                    by my_verification_state. */}
                <form action={saveNote} className="flex flex-wrap gap-2">
                  <input
                    type="hidden"
                    name="request_id"
                    value={r.request_id}
                  />
                  <input
                    type="text"
                    name="internal_note"
                    defaultValue={r.internal_note ?? ""}
                    placeholder="internal note (staff only)"
                    className="input flex-1 min-w-[200px]"
                  />
                  <button type="submit" className="btn-secondary text-xs">
                    Save note
                  </button>
                </form>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
