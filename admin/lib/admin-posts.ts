// Staff read posts from the base table, never the member-facing feed_posts
// view: that view hides shadow-banned and deactivated authors (exactly the
// accounts moderators investigate) and calls a private function the service
// role cannot execute, so every service-role read of it fails.
export const POST_AUTHOR_EMBED =
  "author:users!posts_author_id_fkey(anonymous_pseudonym), persona:personas!posts_persona_id_fkey(pseudonym, deleted_at)";

// Many-to-one embeds arrive as one object; the untyped client infers arrays.
type Embedded<T> = T | T[] | null | undefined;
type AuthorEmbed = {
  author?: Embedded<{ anonymous_pseudonym: string | null }>;
  persona?: Embedded<{ pseudonym: string | null; deleted_at: string | null }>;
};
const one = <T,>(value: Embedded<T>) => (Array.isArray(value) ? value[0] : value) ?? null;

/** The same label feed_posts shows members: active persona first, then the account. */
export function withAuthorPseudonym<T extends AuthorEmbed>(rows: T[] | null | undefined) {
  return (rows ?? []).map(({ author, persona, ...row }) => {
    const p = one(persona), a = one(author);
    return { ...row, author_pseudonym: `@${(p && !p.deleted_at ? p.pseudonym : null) ?? a?.anonymous_pseudonym ?? "anonymous"}` };
  });
}
