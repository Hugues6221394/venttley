-- The tick follows the person, not the screen.
--
-- Verification is a single column, public.users.is_verified, and nothing is
-- denormalised — every author_is_verified / keeper_is_verified you see in the
-- app is a live join. So whether somebody's tick appears is decided one query
-- at a time, and about half the queries drop it on the floor.
--
-- The feed joins it. Whispers join it. Friends join it. Tribe chat joins it.
-- The inbox does not, so a verified friend is plain in the one list people
-- open most. The search centre does not, which means the screen whose entire
-- job is telling you who somebody is cannot tell you the one fact that has
-- been checked. Mention autocomplete does not. Whisper comments do not. The
-- tribe roster does not.
--
-- These are the contracts that drop it. Each one gains a column.

-- ---------------------------------------------------------------------------
-- 1. The inbox.
-- ---------------------------------------------------------------------------
--
-- inbox_rooms already joins users twice, once for each end of a direct room,
-- and takes the pseudonym, the avatar seed and the photo from whichever one is
-- not you. It takes is_verified now too.
--
-- Patched from the live definition rather than restated: the view is ninety
-- lines and has been redefined eight times, most recently two migrations ago.
DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_viewdef('public.inbox_rooms'::regclass, true) INTO v_def;

  IF position('peer_profile_photo_url' IN v_def) = 0 THEN
    RAISE EXCEPTION 'inbox_rooms is not shaped as expected; refusing to patch blind';
  END IF;

  -- Appended, not slotted in beside the other peer columns where it belongs:
  -- CREATE OR REPLACE VIEW can only add columns at the end, and inserting one
  -- fails with "cannot change name of view column" naming whatever used to sit
  -- in that position.
  v_def := replace(
    v_def,
    '    p.cleared_at
   FROM chat_rooms r',
    '    p.cleared_at,
        CASE
            WHEN r.room_kind = ''group''::text THEN false
            WHEN r.initiated_by = auth.uid() THEN COALESCE(peer_recv.is_verified, false)
            ELSE COALESCE(peer_init.is_verified, false)
        END AS peer_is_verified
   FROM chat_rooms r'
  );

  IF position('peer_is_verified' IN v_def) = 0 THEN
    RAISE EXCEPTION 'could not find the end of the inbox_rooms select list';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW public.inbox_rooms WITH (security_invoker = true) AS '
          || v_def;
END;
$$;

GRANT SELECT ON public.inbox_rooms TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.inbox_rooms FROM authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. The search centre.
-- ---------------------------------------------------------------------------
--
-- search_user_hits and search_global have to move together: search_global
-- UNIONs the user arm with tribes, posts and topics, so a thirteenth column on
-- one is a thirteenth column on all four. Both are written out rather than
-- patched, because a UNION that loses its alignment fails at the type level
-- with an error that names the wrong thing.

DROP FUNCTION IF EXISTS public.search_global(TEXT, INT);
DROP FUNCTION IF EXISTS public.search_user_hits(TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.search_user_hits(
  p_username TEXT,
  p_display  TEXT,
  p_limit    INT
) RETURNS TABLE (
  hit_kind TEXT, hit_id TEXT, title TEXT, subtitle TEXT,
  avatar_seed TEXT, profile_photo_url TEXT, member_count INT, post_count INT,
  likes_count INT, comments_count INT, created_at TIMESTAMPTZ, rank_score REAL,
  is_verified BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_viewer UUID := (SELECT auth.uid());
BEGIN
  IF v_viewer IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('global_search', 60, 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  RETURN QUERY
  SELECT
    'user'::TEXT,
    u.user_id::TEXT,
    u.display_name::TEXT,
    ('@' || u.anonymous_pseudonym)::TEXT,
    u.avatar_seed::TEXT,
    u.profile_photo_url::TEXT,
    NULL::INT, NULL::INT, NULL::INT, NULL::INT,
    u.created_at,
    (
      CASE WHEN u.username_normalized = p_username THEN 12.0
           WHEN u.username_normalized LIKE p_username || '%' THEN 8.0
           ELSE 0.0 END
      + CASE WHEN u.display_name_normalized = p_display THEN 10.0
             WHEN u.display_name_normalized LIKE p_display || '%' THEN 7.0
             ELSE public.similarity(u.display_name_normalized, p_display) * 4.0 END
    )::REAL,
    COALESCE(u.is_verified, FALSE)
  FROM public.users AS u
  WHERE u.deactivated_at IS NULL
    AND u.shadow_banned IS NOT TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks AS b
       WHERE (b.blocker_id = v_viewer AND b.blocked_id = u.user_id)
          OR (b.blocked_id = v_viewer AND b.blocker_id = u.user_id)
    )
    AND (
      u.username_normalized = p_username
      OR u.username_normalized LIKE p_username || '%'
      OR u.display_name_normalized LIKE '%' || p_display || '%'
      OR public.similarity(u.display_name_normalized, p_display) > 0.30
    )
  ORDER BY 12 DESC, u.created_at DESC
  LIMIT least(greatest(COALESCE(p_limit, 24), 1), 60);
END;
$$;

REVOKE ALL ON FUNCTION public.search_user_hits(TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_user_hits(TEXT, TEXT, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.search_global(
  p_query TEXT,
  p_limit INT DEFAULT 24
) RETURNS TABLE (
  hit_kind TEXT, hit_id TEXT, title TEXT, subtitle TEXT, avatar_seed TEXT,
  profile_photo_url TEXT, member_count INT, post_count INT, likes_count INT,
  comments_count INT, created_at TIMESTAMPTZ, rank_score REAL,
  is_verified BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_query TEXT := regexp_replace(
    normalize(pg_catalog.btrim(COALESCE(p_query, '')), NFC),
    '[[:space:]]+', ' ', 'g'
  );
  v_normalized TEXT := pg_catalog.lower(regexp_replace(
    normalize(pg_catalog.btrim(COALESCE(p_query, '')), NFC),
    '[[:space:]]+', ' ', 'g'
  ));
  v_username TEXT := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_query, ''), '@'));
  v_pat TEXT;
BEGIN
  IF pg_catalog.char_length(v_query) < 2 THEN RETURN; END IF;
  v_pat := '%' || v_query || '%';

  RETURN QUERY
  WITH blocks AS (
    SELECT b.blocked_id AS user_id
      FROM public.user_blocks AS b
     WHERE b.blocker_id = v_uid
    UNION
    SELECT b.blocker_id
      FROM public.user_blocks AS b
     WHERE b.blocked_id = v_uid
  ),
  user_hits AS (
    SELECT *
      FROM public.search_user_hits(v_username, v_normalized, p_limit)
  ),
  tribe_hits AS (
    SELECT 'tribe'::TEXT, t.slug::TEXT, t.name::TEXT,
           COALESCE(t.description, '')::TEXT,
           NULL::TEXT, NULL::TEXT, COALESCE(t.member_count, 0)::INT,
           NULL::INT, NULL::INT, NULL::INT, t.created_at,
           (CASE WHEN t.name ILIKE v_pat THEN 3.0 ELSE 0 END
            + CASE WHEN t.description ILIKE v_pat THEN 1.0 ELSE 0 END
            + pg_catalog.ln(greatest(COALESCE(t.member_count, 0), 1)) * 0.15)::REAL,
           -- A tribe is not a person and cannot be verified. FALSE rather than
           -- NULL so the client never has to decide what a null tick means.
           FALSE
      FROM public.tribes AS t
     WHERE t.name ILIKE v_pat OR t.description ILIKE v_pat
  ),
  post_hits AS (
    SELECT 'post'::TEXT, p.post_id::TEXT,
           pg_catalog.left(p.content, 240)::TEXT,
           CASE WHEN p.persona_id IS NULL
                THEN COALESCE(u.display_name, p.author_pseudonym, 'Anonymous')
                ELSE COALESCE(p.author_pseudonym, 'Anonymous') END::TEXT,
           COALESCE(p.author_avatar_seed, 'default-orb')::TEXT,
           p.author_profile_photo_url::TEXT,
           NULL::INT, NULL::INT, p.likes_count, p.comments_count, p.created_at,
           (2.0
            + pg_catalog.ln(greatest(p.likes_count + p.comments_count, 1)) * 0.4
            - (extract(EPOCH FROM now() - p.created_at) / 86400.0) * 0.05)::REAL,
           -- A post written behind a persona shows the persona's name, and a
           -- persona is deliberately unverifiable — ticking it would attach a
           -- checked identity to the thing built to hide one.
           CASE WHEN p.persona_id IS NULL
                THEN COALESCE(u.is_verified, FALSE) ELSE FALSE END
      FROM public.feed_posts AS p
      LEFT JOIN public.users AS u ON u.user_id = p.author_id
     WHERE p.is_whisper = FALSE
       AND p.content ILIKE v_pat
       AND (v_uid IS NULL OR p.author_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM blocks AS b WHERE b.user_id = p.author_id
       ))
  ),
  topic_hits AS (
    SELECT 'topic'::TEXT, c.cat::TEXT, c.cat::TEXT,
           ((SELECT count(*) FROM public.posts AS pp
              WHERE pp.category_name = c.cat AND pp.deleted_at IS NULL
                AND pp.created_at > now() - INTERVAL '7 days')::TEXT
             || ' posts in last 7d')::TEXT,
           NULL::TEXT, NULL::TEXT, NULL::INT,
           (SELECT count(*)::INT FROM public.posts AS pp
             WHERE pp.category_name = c.cat AND pp.deleted_at IS NULL
               AND pp.created_at > now() - INTERVAL '7 days'),
           NULL::INT, NULL::INT, NULL::TIMESTAMPTZ, 2.5::REAL,
           FALSE
      FROM (VALUES
        ('confessions'),('testimonies'),('relationships'),('family_issues'),
        ('mental_health'),('campus_life'),('adulting'),('regrets'),('trauma'),
        ('friendship'),('faith_spirituality'),('questions'),('secrets'),
        ('vent_zone'),('dark_thoughts'),('funny_confessions'),('dreams_goals'),
        ('hot_takes'),('late_night'),('healing_corner')
      ) AS c(cat)
     WHERE c.cat ILIKE v_pat
  )
  SELECT *
    FROM (
      SELECT * FROM user_hits
      UNION ALL SELECT * FROM tribe_hits
      UNION ALL SELECT * FROM post_hits
      UNION ALL SELECT * FROM topic_hits
    ) AS merged
   ORDER BY rank_score DESC NULLS LAST, created_at DESC NULLS LAST
   LIMIT greatest(1, least(COALESCE(p_limit, 24), 60));
END;
$$;

REVOKE ALL ON FUNCTION public.search_global(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_global(TEXT, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Mention autocomplete.
-- ---------------------------------------------------------------------------
--
-- The list you pick a name from when you type @. Already joins users for the
-- handle, the display name and the avatar seed.

DROP FUNCTION IF EXISTS public.search_tag_candidates(TEXT, INT);

CREATE OR REPLACE FUNCTION public.search_tag_candidates(
  p_prefix TEXT,
  p_limit  INT DEFAULT 8
) RETURNS TABLE (
  kind TEXT, id UUID, handle TEXT, display TEXT, avatar_seed TEXT,
  is_friend BOOLEAN, is_verified BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_prefix TEXT := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_prefix, ''), '@'));
  v_limit INT := least(greatest(COALESCE(p_limit, 8), 1), 15);
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF pg_catalog.char_length(v_prefix) < 1 THEN RETURN; END IF;

  RETURN QUERY
  (
    SELECT 'user'::TEXT, u.user_id, u.anonymous_pseudonym::TEXT,
           u.display_name::TEXT, u.avatar_seed::TEXT,
           EXISTS (SELECT 1 FROM public.friendships AS f
                    WHERE f.status = 'accepted'
                      AND ((f.user_a = v_me AND f.user_b = u.user_id)
                        OR (f.user_b = v_me AND f.user_a = u.user_id))) AS is_friend,
           COALESCE(u.is_verified, FALSE)
      FROM public.users AS u
     WHERE u.username_normalized LIKE v_prefix || '%'
       AND u.deactivated_at IS NULL
       AND u.shadow_banned IS NOT TRUE
       AND u.user_id <> v_me
     ORDER BY is_friend DESC, pg_catalog.char_length(u.anonymous_pseudonym)
     LIMIT v_limit
  )
  UNION ALL
  (
    SELECT 'tribe'::TEXT, t.tribe_id, t.slug::TEXT, t.name::TEXT, NULL::TEXT,
           FALSE, FALSE
      FROM public.tribes AS t
     WHERE pg_catalog.lower(t.slug) LIKE v_prefix || '%'
        OR pg_catalog.lower(t.name) LIKE v_prefix || '%'
     ORDER BY pg_catalog.char_length(t.slug)
     LIMIT 4
  );
END;
$$;

REVOKE ALL ON FUNCTION public.search_tag_candidates(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_tag_candidates(TEXT, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Whisper comments.
-- ---------------------------------------------------------------------------
--
-- Same persona rule as the post search arm: a comment left behind a persona
-- shows the persona's name, and a persona must never carry a tick.
DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'list_whisper_comments';

  IF v_def IS NULL OR position('can_delete boolean' IN v_def) = 0 THEN
    RAISE EXCEPTION 'list_whisper_comments is not shaped as expected';
  END IF;

  v_def := replace(v_def, 'can_delete boolean)',
                          'can_delete boolean, author_is_verified boolean)');
  v_def := replace(v_def, '(c.author_id = v_me OR w.author_id = v_me)',
                          '(c.author_id = v_me OR w.author_id = v_me),
        CASE WHEN c.persona_id IS NULL
             THEN COALESCE(u.is_verified, FALSE) ELSE FALSE END');

  EXECUTE 'DROP FUNCTION IF EXISTS public.list_whisper_comments(UUID, INT, INT)';
  EXECUTE v_def || ';';
END;
$$;

REVOKE ALL ON FUNCTION public.list_whisper_comments(UUID, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_whisper_comments(UUID, INT, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. The tribe roster, online.
-- ---------------------------------------------------------------------------
--
-- Returns jsonb, so a new key is additive and nothing has to be dropped.
DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'tribe_online_members';

  IF v_def IS NULL OR position('u.profile_photo_url,' IN v_def) = 0 THEN
    RAISE EXCEPTION 'tribe_online_members is not shaped as expected';
  END IF;

  v_def := replace(
    v_def,
    'u.profile_photo_url,',
    'u.profile_photo_url,
                u.display_name,
                COALESCE(u.is_verified, FALSE) AS is_verified,'
  );

  EXECUTE v_def || ';';
END;
$$;

SELECT public.record_migration(
  '20261049090000', 'a_tick_travels_with_the_name'
);

NOTIFY pgrst, 'reload schema';
