-- Let a keeper find people to invite by typing, instead of by knowing.
--
-- The invite box asked for an exact handle and looked it up once, on a button
-- press, with ILIKE and no wildcards. Get a character wrong and the answer was
-- "No user found with that username" — indistinguishable from "that person does
-- not exist". Every other search surface in the app had moved on years ago;
-- this one had not.
--
-- A dedicated function rather than reusing search_tag_candidates, for two
-- reasons that only apply here:
--
--   * Authorization. Inviting is keeper-only — that is what the
--     "invites keeper insert" policy on tribe_invites enforces. A picker that
--     lists candidates to somebody who cannot invite them is a list of names
--     handed out for nothing, so this checks the same condition the insert
--     will, and raises rather than returning an empty set so the client can
--     tell "not allowed" from "no matches".
--
--   * The two answers a keeper actually needs are about the tribe, not the
--     person: is this one already in, and have I already asked them. Without
--     those the picker invites somebody who is already a member, the unique
--     constraint on (tribe_id, invited_user_id) swallows it, and the keeper is
--     told an invitation was sent that nobody will ever receive.
--
-- Blocks are honoured in both directions. search_tag_candidates does not do
-- this, which is arguably a bug there; here it plainly is one — an invite is a
-- notification, and somebody who blocked the keeper should not get one.

CREATE OR REPLACE FUNCTION public.search_tribe_invite_candidates(
  p_tribe_id UUID,
  p_query    TEXT,
  p_limit    INT DEFAULT 12
) RETURNS TABLE (
  user_id         UUID,
  pseudonym       TEXT,
  display_name    TEXT,
  avatar_seed     TEXT,
  profile_photo_url TEXT,
  is_verified     BOOLEAN,
  is_friend       BOOLEAN,
  already_member  BOOLEAN,
  already_invited BOOLEAN
)
LANGUAGE plpgsql
-- VOLATILE, not STABLE: claim_rate_limit writes, and Postgres refuses a write
-- from a non-volatile function at call time rather than at definition time —
-- so the wrong marker here creates cleanly and fails on the first keystroke.
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me     UUID := (SELECT auth.uid());
  v_handle TEXT := pg_catalog.lower(pg_catalog.btrim(pg_catalog.btrim(COALESCE(p_query, '')), '@'));
  v_name   TEXT := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_query, '')));
  v_limit  INT  := least(greatest(COALESCE(p_limit, 12), 1), 30);
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  -- The same test the insert policy applies. Answering this here means the
  -- picker and the button agree about who may invite.
  IF NOT EXISTS (
    SELECT 1 FROM public.tribes AS t
     WHERE t.tribe_id = p_tribe_id AND t.keeper_id = v_me
  ) THEN
    RAISE EXCEPTION 'not_the_keeper';
  END IF;

  -- One character is not a search, it is the whole member list sorted oddly.
  IF pg_catalog.char_length(v_handle) < 2 THEN
    RETURN;
  END IF;

  -- Typing is the trigger now, so this runs far more often than the old button
  -- did. Generous enough that nobody types into it, tight enough that it is not
  -- a free way to walk the user table.
  IF NOT public.claim_rate_limit('invite_search', 60, 150) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  RETURN QUERY
  SELECT
    u.user_id,
    u.anonymous_pseudonym::TEXT,
    u.display_name::TEXT,
    u.avatar_seed::TEXT,
    u.profile_photo_url::TEXT,
    COALESCE(u.is_verified, FALSE),
    EXISTS (
      SELECT 1 FROM public.friendships AS f
       WHERE f.status = 'accepted'
         AND ((f.user_a = v_me AND f.user_b = u.user_id)
           OR (f.user_b = v_me AND f.user_a = u.user_id))
    ),
    EXISTS (
      SELECT 1 FROM public.tribe_members AS m
       WHERE m.tribe_id = p_tribe_id AND m.user_id = u.user_id
    ),
    EXISTS (
      SELECT 1 FROM public.tribe_invites AS i
       WHERE i.tribe_id = p_tribe_id
         AND i.invited_user_id = u.user_id
         AND i.status = 'pending'
    )
  FROM public.users AS u
  WHERE u.user_id <> v_me
    AND u.deactivated_at IS NULL
    AND u.shadow_banned IS NOT TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks AS b
       WHERE (b.blocker_id = v_me AND b.blocked_id = u.user_id)
          OR (b.blocked_id = v_me AND b.blocker_id = u.user_id)
    )
    AND (
      u.username_normalized LIKE v_handle || '%'
      OR u.display_name_normalized LIKE '%' || v_name || '%'
      OR public.similarity(u.display_name_normalized, v_name) > 0.30
    )
  ORDER BY
    -- People you already know, first. A keeper inviting somebody usually has
    -- somebody in mind, and the tribe they run is mostly built out of friends.
    (EXISTS (
       SELECT 1 FROM public.friendships AS f
        WHERE f.status = 'accepted'
          AND ((f.user_a = v_me AND f.user_b = u.user_id)
            OR (f.user_b = v_me AND f.user_a = u.user_id))
     )) DESC,
    (u.username_normalized = v_handle) DESC,
    (u.username_normalized LIKE v_handle || '%') DESC,
    public.similarity(u.display_name_normalized, v_name) DESC,
    pg_catalog.char_length(u.anonymous_pseudonym)
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.search_tribe_invite_candidates(UUID, TEXT, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_tribe_invite_candidates(UUID, TEXT, INT)
  TO authenticated;

-- Prefix matching on a handle had no index it could use.
--
-- 0119 added a trigram index on anonymous_pseudonym, but every search function
-- written since matches on username_normalized — a different column, so the
-- index never applied. `EXPLAIN` on `username_normalized LIKE 'tes%'` is a
-- sequential scan, and a btree on a default-collation text column cannot serve
-- a prefix LIKE anyway. At fourteen rows that is invisible. At the scale this
-- is being built for it is a full table read per keystroke, on the one query
-- that now runs per keystroke.
--
-- Trigram GIN serves both shapes: LIKE 'abc%' and similarity(). It also speeds
-- up search_tag_candidates and search_user_hits, which have been paying for
-- this all along.
CREATE INDEX IF NOT EXISTS users_username_normalized_trgm
  ON public.users USING gin (username_normalized public.gin_trgm_ops);

SELECT public.record_migration(
  '20261044090000', 'invite_search_finds_people'
);

NOTIFY pgrst, 'reload schema';
