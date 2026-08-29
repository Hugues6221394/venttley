-- Move the Tribe category list out of the Flutter binary.
--
-- The sixteen categories were a `static const` in create_tribe_screen.dart and
-- separately in four other files. Adding one meant a code change and an app
-- store release, and the copies had already begun to answer differently —
-- which for a value written into every tribes row and used for discovery
-- filtering is a slow-moving data problem, not a styling one.
--
-- Split: the database owns which categories exist, what they are called and
-- what order they appear in. The client keeps the icon, because an icon is a
-- Flutter symbol and putting a widget reference in a table would only move the
-- coupling somewhere harder to see. Unknown keys get a neutral default, so a
-- category added here shows up in the app immediately without a release.
--
-- Seeded with exactly the current sixteen and their current keys. Existing
-- tribes carry those keys, so anything else would orphan live rows.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tribe_categories (
  category_key TEXT PRIMARY KEY
    CHECK (category_key ~ '^[a-z][a-z0-9_]{1,30}$'),
  label        TEXT NOT NULL CHECK (char_length(btrim(label)) BETWEEN 1 AND 40),
  sort_order   INT  NOT NULL DEFAULT 100,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.tribe_categories IS
  'Controlled taxonomy for Tribe categories. Read by the client; never written by it.';

CREATE INDEX IF NOT EXISTS tribe_categories_active_order_idx
  ON public.tribe_categories (sort_order, category_key)
  WHERE is_active;

ALTER TABLE public.tribe_categories ENABLE ROW LEVEL SECURITY;

-- Readable by any signed-in account, written by nobody through the API. The
-- list is not secret, but it is not user data either — it changes by migration
-- or by an operator, never by a client.
REVOKE ALL ON public.tribe_categories FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tribe_categories TO authenticated;

DROP POLICY IF EXISTS tribe_categories_read ON public.tribe_categories;
CREATE POLICY tribe_categories_read
  ON public.tribe_categories
  FOR SELECT
  TO authenticated
  USING (TRUE);

-- The current sixteen, in the order they are shown today. ON CONFLICT DO
-- NOTHING so re-running never disturbs labels an operator has since edited.
INSERT INTO public.tribe_categories (category_key, label, sort_order) VALUES
  ('campus',         'Campus',     10),
  ('city',           'City',       20),
  ('interest_group', 'Interest',   30),
  ('hobby',          'Hobby',      40),
  ('support',        'Support',    50),
  ('venting',        'Venting',    60),
  ('wellness',       'Wellness',   70),
  ('creativity',     'Creativity', 80),
  ('faith',          'Faith',      90),
  ('lgbtq',          'LGBTQ+',    100),
  ('grief',          'Grief',     110),
  ('growth',         'Growth',    120),
  ('study',          'Study',     130),
  ('gaming',         'Gaming',    140),
  ('music',          'Music',     150),
  ('fitness',        'Fitness',   160)
ON CONFLICT (category_key) DO NOTHING;

COMMIT;

SELECT public.record_migration(
  '20260830090000', 'tribe_category_taxonomy'
);

NOTIFY pgrst, 'reload schema';
