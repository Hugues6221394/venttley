-- 0039_global_search.sql
--
-- One-round-trip search backing the Discover screen's search field.
-- Returns a heterogeneous result set tagged by `hit_kind` so the client
-- can render the three result types (tribe / post / topic) with one call.
--
-- Ranking notes:
--   * tribe matches: name ILIKE first, then description ILIKE; secondary
--     order is member_count DESC so the biggest community wins ties
--   * post matches: content ILIKE, ranked by recency × engagement;
--     whispers are excluded because they expire in 24h and the search
--     result list outlives that window
--   * topic matches: substring match against the static category enum
--     surfaced through a small VALUES list (kept inline so we don't
--     need a separate table for 20 strings)
--
-- Caller-blocked authors are filtered out so the search surface honours
-- the user_blocks graph the same way the feed does.

CREATE OR REPLACE FUNCTION public.search_global(
    p_query TEXT,
    p_limit INT DEFAULT 24
) RETURNS TABLE (
    hit_kind          TEXT,        -- 'tribe' | 'post' | 'topic'
    hit_id            TEXT,        -- tribe slug, post_id, category key
    title             TEXT,        -- tribe name, post excerpt, category label
    subtitle          TEXT,        -- tribe description, author handle, "N posts"
    avatar_seed       TEXT,        -- tribe slug placeholder, author seed, null
    profile_photo_url TEXT,        -- author photo if default-profile post
    member_count      INT,         -- tribes only
    post_count        INT,         -- topics only
    likes_count       INT,         -- posts only
    comments_count    INT,         -- posts only
    created_at        TIMESTAMPTZ, -- posts/tribes
    rank_score        REAL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_pat TEXT;
BEGIN
    IF p_query IS NULL OR length(trim(p_query)) < 2 THEN
        RETURN;
    END IF;
    v_pat := '%' || trim(p_query) || '%';

    RETURN QUERY
    WITH
    blocks AS (
        SELECT blocked_id FROM user_blocks WHERE blocker_id = v_uid
    ),
    tribe_hits AS (
        SELECT
            'tribe'::TEXT                                 AS hit_kind,
            t.slug                                        AS hit_id,
            t.name::TEXT                                  AS title,
            COALESCE(t.description, '')::TEXT             AS subtitle,
            NULL::TEXT                                    AS avatar_seed,
            NULL::TEXT                                    AS profile_photo_url,
            COALESCE(t.member_count, 0)                   AS member_count,
            NULL::INT                                     AS post_count,
            NULL::INT                                     AS likes_count,
            NULL::INT                                     AS comments_count,
            t.created_at                                  AS created_at,
            (
              CASE WHEN t.name ILIKE v_pat        THEN 3.0 ELSE 0 END
            + CASE WHEN t.description ILIKE v_pat THEN 1.0 ELSE 0 END
            + (ln(GREATEST(COALESCE(t.member_count, 0), 1)) * 0.15)
            )::REAL                                       AS rank_score
          FROM tribes t
         WHERE t.name ILIKE v_pat OR t.description ILIKE v_pat
    ),
    post_hits AS (
        SELECT
            'post'::TEXT                                  AS hit_kind,
            p.post_id::TEXT                               AS hit_id,
            LEFT(p.content, 240)::TEXT                    AS title,
            COALESCE(u.anonymous_pseudonym, 'anonymous')::TEXT AS subtitle,
            COALESCE(u.avatar_seed, 'default-orb')::TEXT  AS avatar_seed,
            u.profile_photo_url::TEXT                     AS profile_photo_url,
            NULL::INT                                     AS member_count,
            NULL::INT                                     AS post_count,
            p.likes_count                                 AS likes_count,
            p.comments_count                              AS comments_count,
            p.created_at                                  AS created_at,
            (
              2.0
            + ln(GREATEST(p.likes_count + p.comments_count, 1)) * 0.4
            - (extract(epoch from now() - p.created_at) / 86400.0) * 0.05
            )::REAL                                       AS rank_score
          FROM posts p
          LEFT JOIN users u ON u.user_id = p.author_id
         WHERE p.deleted_at IS NULL
           AND p.is_whisper = FALSE
           AND p.content ILIKE v_pat
           AND (v_uid IS NULL
                OR p.author_id IS NULL
                OR NOT EXISTS (
                     SELECT 1 FROM blocks b WHERE b.blocked_id = p.author_id
                   ))
    ),
    topic_hits AS (
        SELECT
            'topic'::TEXT                                 AS hit_kind,
            c.cat                                         AS hit_id,
            c.cat                                         AS title,
            (
              SELECT COUNT(*)::TEXT || ' posts in last 7d'
                FROM posts pp
               WHERE pp.category_name = c.cat
                 AND pp.deleted_at IS NULL
                 AND pp.created_at > now() - INTERVAL '7 days'
            )::TEXT                                       AS subtitle,
            NULL::TEXT                                    AS avatar_seed,
            NULL::TEXT                                    AS profile_photo_url,
            NULL::INT                                     AS member_count,
            (
              SELECT COUNT(*)::INT FROM posts pp
               WHERE pp.category_name = c.cat
                 AND pp.deleted_at IS NULL
                 AND pp.created_at > now() - INTERVAL '7 days'
            )                                             AS post_count,
            NULL::INT                                     AS likes_count,
            NULL::INT                                     AS comments_count,
            NULL::TIMESTAMPTZ                             AS created_at,
            2.5::REAL                                     AS rank_score
          FROM (
            VALUES
              ('confessions'),('testimonies'),('relationships'),
              ('family_issues'),('mental_health'),('campus_life'),
              ('adulting'),('regrets'),('trauma'),('friendship'),
              ('faith_spirituality'),('questions'),('secrets'),
              ('vent_zone'),('dark_thoughts'),('funny_confessions'),
              ('dreams_goals'),('hot_takes'),('late_night'),
              ('healing_corner')
          ) AS c(cat)
         WHERE c.cat ILIKE v_pat
    )
    SELECT * FROM (
        SELECT * FROM tribe_hits
        UNION ALL
        SELECT * FROM post_hits
        UNION ALL
        SELECT * FROM topic_hits
    ) merged
    ORDER BY rank_score DESC NULLS LAST, created_at DESC NULLS LAST
    LIMIT GREATEST(1, LEAST(p_limit, 60));
END $$;

REVOKE ALL ON FUNCTION public.search_global(TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_global(TEXT, INT) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
