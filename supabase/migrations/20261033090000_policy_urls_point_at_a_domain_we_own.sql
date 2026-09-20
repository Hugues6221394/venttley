-- The published Privacy Policy and Terms URLs point at a domain that does not exist.
--
--   privacy  ->  https://venttly.app/privacy
--   terms    ->  https://venttly.app/terms
--
-- venttly.app has no DNS record at all -- not a parked page, not a 404, no
-- answer. The domain we own is venttly.com. Both App Store Connect and Google
-- Play require a privacy policy URL that resolves, and a reviewer following a
-- dead link is a rejection rather than a question.
--
-- This was survivable until now only because the app never opens body_url: the
-- onboarding reader renders body_markdown from this same row, so members have
-- always seen the real text. The URL is what the outside world gets -- store
-- listings, a regulator, anyone asking "where is your privacy policy" -- and
-- it has been broken since the documents were first published.
--
-- The site now serving those paths reads body_markdown from these rows over
-- PostgREST with the publishable key, so the page and the app cannot drift:
-- there is one copy of the text and both render it.
--
-- Not a new version, and deliberately so. policy_acceptances is keyed on
-- (user_id, kind, version), and `material` marks changes that require fresh
-- consent. Correcting a link is neither: the text every member accepted is
-- byte-for-byte the text they still see. Bumping the version here would demand
-- re-acceptance from the whole member base for a typo in a URL, and teach
-- people that the consent prompt means nothing.
--
-- Scoped to the exact prefix rather than rewriting every body_url, so a row
-- that has already been corrected, or that legitimately points somewhere else,
-- is left alone.

BEGIN;

DO $$
DECLARE
  v_fixed INTEGER;
BEGIN
  UPDATE public.policy_documents
     SET body_url = 'https://venttly.com' ||
                    substring(body_url FROM length('https://venttly.app') + 1)
   WHERE body_url LIKE 'https://venttly.app/%';

  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE 'repointed % policy document url(s) to venttly.com', v_fixed;
END $$;

COMMENT ON COLUMN public.policy_documents.body_url IS
  'Where this document is published for people who are not in the app -- store '
  'listings link here, and it must resolve. Served by the site in site/, which '
  'renders body_markdown from this same row so the two cannot disagree. It '
  'pointed at venttly.app, a domain with no DNS, until 20261033090000.';

SELECT public.record_migration(
  '20261033090000', 'policy_urls_point_at_a_domain_we_own'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
