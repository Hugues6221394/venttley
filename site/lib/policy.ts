/**
 * The public site reads its legal text from the same rows the app reads.
 *
 * `policy_documents` is the one source of truth: the Flutter client renders
 * `body_markdown` during onboarding, `private.assert_user_can_write` refuses
 * content writes from anyone who has not accepted the current version, and
 * these pages render that same column. There is no second copy to drift,
 * which matters more here than anywhere else — a privacy policy that says one
 * thing in the app and another on the web is worse than having only one.
 *
 * Read with the publishable key over PostgREST. The table grants SELECT to
 * `anon` under an RLS policy of `USING (true)`, so no server-side secret is
 * involved and this cannot reach any other table.
 */

export type PolicyKind = "privacy" | "terms";

export type PolicyDocument = {
  kind: PolicyKind;
  version: string;
  title: string;
  summary: string | null;
  body_markdown: string;
  effective_at: string | null;
};

export async function fetchPolicy(kind: PolicyKind): Promise<PolicyDocument> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    throw new Error(
      "NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY must be set",
    );
  }

  // `retired_at IS NULL` marks the version currently in force. Superseded
  // versions stay in the table so an acceptance recorded long ago can still be
  // resolved to the exact text that was accepted.
  const query = new URLSearchParams({
    select: "kind,version,title,summary,body_markdown,effective_at",
    kind: `eq.${kind}`,
    retired_at: "is.null",
    order: "version.desc",
    limit: "1",
  });

  const response = await fetch(`${url}/rest/v1/policy_documents?${query}`, {
    headers: { apikey: key, Authorization: `Bearer ${key}` },
    // Revalidated rather than baked in at build: publishing a new version
    // should reach this page without anyone remembering to redeploy.
    next: { revalidate: 300 },
  });

  if (!response.ok) {
    throw new Error(
      `policy_documents fetch failed: ${response.status} ${response.statusText}`,
    );
  }

  const rows: PolicyDocument[] = await response.json();
  // Throw rather than render an empty page. A blank privacy policy served with
  // a 200 is the failure nobody notices; a 500 gets looked at.
  if (!rows.length) throw new Error(`no current ${kind} policy document`);
  return rows[0];
}
