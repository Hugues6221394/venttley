-- Who among your friends is around right now, in one query.
--
-- The inbox wants a strip of people you could message this second. The only
-- presence primitive today is peer_presence(user_id) — one row per call — so
-- building that strip on the client meant one round trip per friend. At a
-- hundred friends that is a hundred requests every time the inbox opens, and
-- the app is explicitly built for people on slow connections.
--
-- ## Privacy
--
-- `show_last_seen` is an opt-in, and peer_presence returns 'hidden' when it is
-- off. This function does not merely hide the *timestamp* for those users — it
-- omits them from the result entirely. Appearing in a "who is around" list is
-- itself presence information, so a user who turned last-seen off must not show
-- up in it at all. Same thresholds as peer_presence (70s online, 5m recent) so
-- the two can never disagree about the same person.
--
-- Blocks are honoured in both directions, and only accepted friendships count.

CREATE OR REPLACE FUNCTION public.online_friends(p_limit INT DEFAULT 12)
RETURNS TABLE (
  user_id           UUID,
  pseudonym         TEXT,
  display_name      TEXT,
  avatar_seed       TEXT,
  profile_photo_url TEXT,
  is_verified       BOOLEAN,
  state             TEXT,
  last_seen_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN RETURN; END IF;

  RETURN QUERY
  WITH my_friends AS (
      SELECT CASE WHEN f.user_a = v_me THEN f.user_b ELSE f.user_a END AS fid
        FROM friendships f
       WHERE f.status = 'accepted'
         AND v_me IN (f.user_a, f.user_b)
  ),
  blocked AS (
      SELECT b.blocked_id AS other_id FROM user_blocks b WHERE b.blocker_id = v_me
      UNION
      SELECT b.blocker_id AS other_id FROM user_blocks b WHERE b.blocked_id = v_me
  )
  SELECT u.user_id,
         u.anonymous_pseudonym,
         u.display_name,
         COALESCE(u.avatar_seed, 'default-orb'),
         u.profile_photo_url,
         COALESCE(u.is_verified, FALSE),
         CASE
           WHEN u.last_seen_at > now() - INTERVAL '70 seconds' THEN 'online'
           ELSE 'recent'
         END,
         u.last_seen_at
    FROM my_friends mf
    JOIN users u ON u.user_id = mf.fid
   WHERE u.user_id NOT IN (SELECT other_id FROM blocked)
     AND u.account_status = 'active'
     AND u.deactivated_at IS NULL
     -- Opt-in only. Omitted entirely, not merely undated: being listed as
     -- "around" is presence information in its own right.
     AND u.show_last_seen IS TRUE
     AND u.last_seen_at IS NOT NULL
     AND u.last_seen_at > now() - INTERVAL '5 minutes'
   ORDER BY u.last_seen_at DESC
   LIMIT GREATEST(COALESCE(p_limit, 12), 1);
END $$;

REVOKE ALL ON FUNCTION public.online_friends(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_friends(INT) TO authenticated;

-- The lookup is "my friends, ordered by recency of presence". Without this the
-- filter is a scan of users for every inbox open.
CREATE INDEX IF NOT EXISTS users_last_seen_visible_idx
  ON public.users (last_seen_at DESC)
  WHERE show_last_seen IS TRUE AND last_seen_at IS NOT NULL;
