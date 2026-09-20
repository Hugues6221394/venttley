import { fetchPolicy, type PolicyKind } from "@/lib/policy";
import { renderMarkdown } from "@/lib/markdown";

/**
 * Both legal pages are the same page with a different `kind`.
 *
 * The heading comes from the document's own `title` rather than being written
 * here, so the page cannot claim to be a Privacy Policy while rendering the
 * Terms. Same reason the version and effective date are printed: a visitor —
 * or a store reviewer, or a regulator — should be able to see which version
 * they are looking at without taking our word for it.
 */
export default async function PolicyPage({ kind }: { kind: PolicyKind }) {
  const doc = await fetchPolicy(kind);
  const html = renderMarkdown(doc.body_markdown);

  const effective = doc.effective_at
    ? new Date(doc.effective_at).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "long",
        year: "numeric",
      })
    : null;

  return (
    <main>
      <div className="wrap">
        <p className="meta">
          Version {doc.version}
          {effective ? ` · in force since ${effective}` : null}
          {" · "}
          This is the same text the app shows when you accept it.
        </p>

        {/* Trusted input: policy_documents is writable only by service_role,
            and renderMarkdown escapes every line before emitting a tag. */}
        <article dangerouslySetInnerHTML={{ __html: html }} />
      </div>
    </main>
  );
}

/** Title and description for the route, taken from the document itself. */
export async function policyMetadata(kind: PolicyKind) {
  try {
    const doc = await fetchPolicy(kind);
    return {
      title: doc.title,
      description: doc.summary ?? undefined,
      alternates: { canonical: `/${kind}` },
    };
  } catch {
    // A failed fetch must not take the whole route down at metadata time; the
    // page body will surface the error properly.
    return { title: kind === "privacy" ? "Privacy Policy" : "Terms" };
  }
}
