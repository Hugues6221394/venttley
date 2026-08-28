-- 0020_crisis_detection.sql
--
-- Surface crisis helplines on posts the safety classifier flagged for
-- self-harm or suicidal ideation. Two pieces:
--
--   1. posts.crisis_level — null when the classifier saw nothing concerning,
--      'elevated' or 'high' when a safety rule identified self-harm risk.
--      Readers see a
--      helpline banner at the top of the post detail view.
--
--   2. crisis_resources — region-tagged helplines (Rwanda first, global
--      fallback). Public-read so the banner can be assembled client-side
--      from the user's location_bucket. Editable later without an app push.
--
-- The author-side write path goes through set_post_crisis (SECURITY DEFINER,
-- owner-only) so clients can't tag arbitrary posts.

-- ---------------------------------------------------------------------------
-- 1) posts.crisis_level
-- ---------------------------------------------------------------------------
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS crisis_level TEXT
    CHECK (crisis_level IN ('elevated', 'high'));

CREATE INDEX IF NOT EXISTS posts_crisis_level_idx
    ON public.posts (crisis_level)
    WHERE crisis_level IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) crisis_resources catalogue
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.crisis_resources (
    resource_id   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    region        TEXT         NOT NULL,     -- 'global' | ISO country code | city/region
    label         TEXT         NOT NULL,
    reach         TEXT         NOT NULL,     -- "Call 114", "Text CARE to 741741"
    url           TEXT,
    hours         TEXT         NOT NULL DEFAULT '24/7',
    sort_order    INT          NOT NULL DEFAULT 100,
    is_active     BOOLEAN      NOT NULL DEFAULT true,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

ALTER TABLE public.crisis_resources ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "crisis read all" ON public.crisis_resources;
CREATE POLICY "crisis read all"
    ON public.crisis_resources FOR SELECT
    USING (is_active = true);

GRANT SELECT ON public.crisis_resources TO anon, authenticated;

-- Seed: Rwanda + global. Founder can edit/extend via the admin app later.
INSERT INTO public.crisis_resources (region, label, reach, url, hours, sort_order) VALUES
    ('RW',     'Rwanda Mental Health Helpline', 'Call 114 (free, 24/7)', NULL,                          '24/7',  10),
    ('RW',     'Isange One Stop Centre',        'Call 3029 from any phone', 'https://rib.gov.rw/isange', '24/7',  20),
    ('global', 'International Befrienders',     'Find a local line',     'https://befrienders.org',     '24/7',  30),
    ('global', 'Crisis Text Line',              'Text CARE to 741741',   'https://www.crisistextline.org','24/7', 40),
    ('global', 'IASP Crisis Centres',           'Directory by country',  'https://www.iasp.info/crisis-centres-helplines/', '24/7', 50)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) set_post_crisis — author-only write path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_post_crisis(
    p_post_id UUID,
    p_level   TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_author UUID;
BEGIN
    IF p_level IS NOT NULL AND p_level NOT IN ('elevated', 'high') THEN
        RAISE EXCEPTION 'invalid crisis level: %', p_level;
    END IF;

    SELECT author_id INTO v_author
      FROM posts
     WHERE post_id = p_post_id;

    IF v_author IS NULL THEN
        RAISE EXCEPTION 'post not found';
    END IF;
    IF v_author <> auth.uid() THEN
        RAISE EXCEPTION 'only the author can tag a post';
    END IF;

    UPDATE posts SET crisis_level = p_level WHERE post_id = p_post_id;
END $$;

REVOKE ALL ON FUNCTION public.set_post_crisis(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_post_crisis(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) Rewire views to surface crisis_level
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.feed_hot   CASCADE;
DROP VIEW IF EXISTS public.feed_posts CASCADE;

CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE(
        '@' || pr.pseudonym,
        '@' || u.anonymous_pseudonym,
        '@anonymous'
    ) AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS author_avatar_seed,
    COALESCE(u.is_verified, false) AS author_is_verified,
    COALESCE(u.karma_points, 0)    AS author_karma,
    p.persona_id,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_whisper,
    p.location_bucket,
    p.likes_count,
    p.comments_count,
    p.crisis_level,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users    u  ON u.user_id     = p.author_id
LEFT JOIN public.personas pr ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
LEFT JOIN public.tribes   t  ON t.tribe_id    = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

CREATE VIEW public.feed_hot WITH (security_invoker = true) AS
SELECT f.*, h.hot_score
  FROM public.feed_posts f
  JOIN public.mv_hot_posts h ON h.post_id = f.post_id;
GRANT SELECT ON public.feed_hot TO authenticated, anon;
