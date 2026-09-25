-- The rate limiter stops failing when two requests arrive together.
--
-- Found by load testing: twenty-five concurrent clients calling search, and
-- every one of them died with
--
--   ERROR: duplicate key value violates unique constraint "rate_limits_pkey"
--
-- claim_rate_limit did a read-then-insert:
--
--   SELECT * INTO v_row FROM rate_limits
--    WHERE user_id = v_uid AND action_key = p_action_key FOR UPDATE;
--   IF NOT FOUND THEN
--     INSERT INTO rate_limits ...
--
-- FOR UPDATE cannot lock a row that does not exist. So the lock does nothing
-- on the first call for a given (user, action) pair, both sessions find
-- nothing, and both insert. One of them gets a primary key violation, which
-- reaches the user as a failed request rather than as a rate-limit decision.
--
-- It is only the first call that races — every later one finds the row and the
-- lock works. That is why it never showed up in ordinary use and why it is
-- exactly the kind of thing that appears when a lot of people arrive at once:
-- a new account whose first two actions overlap, or any account after the
-- cleanup job has removed its row.
--
-- The fix is to let the database decide, which is what ON CONFLICT is for. One
-- statement, no window between the read and the write, nothing to race.

CREATE OR REPLACE FUNCTION public.claim_rate_limit(
  p_action_key     TEXT,
  p_window_seconds INT,
  p_max_count      INT
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     UUID := (SELECT auth.uid());
  v_now     TIMESTAMPTZ := pg_catalog.now();
  v_counter INT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  INSERT INTO public.rate_limits AS r (user_id, action_key, window_started_at, counter)
  VALUES (v_uid, p_action_key, v_now, 1)
  ON CONFLICT (user_id, action_key) DO UPDATE
     -- The window has run out, so this call starts a fresh one; otherwise it
     -- counts against the window already open. Both arms are evaluated against
     -- the stored row, so concurrent callers serialise on the row lock ON
     -- CONFLICT takes for them rather than colliding on the key.
     SET window_started_at = CASE
           WHEN r.window_started_at
                + pg_catalog.make_interval(secs => p_window_seconds) <= v_now
           THEN v_now
           ELSE r.window_started_at
         END,
         counter = CASE
           WHEN r.window_started_at
                + pg_catalog.make_interval(secs => p_window_seconds) <= v_now
           THEN 1
           ELSE r.counter + 1
         END
  RETURNING r.counter INTO v_counter;

  -- The counter keeps climbing while somebody is over the limit, where the old
  -- version pinned it at the maximum. Neither is visible to a caller: both say
  -- no until the window turns over, and the window turns over on time rather
  -- than on the count.
  RETURN v_counter <= p_max_count;
END;
$$;

-- Nobody but the owner calls this directly.
--
-- Every one of its thirty-seven callers is SECURITY DEFINER, so the claim
-- happens as the function owner and the signed-in caller never needs EXECUTE.
-- Granting it would let anybody burn their own budget, or probe the limits,
-- and 0009_internal_helper_acl asserts exactly that — it caught this when an
-- earlier draft of this migration handed the grant to authenticated.
REVOKE ALL ON FUNCTION public.claim_rate_limit(TEXT, INT, INT)
  FROM PUBLIC, anon, authenticated;

SELECT public.record_migration(
  '20261053090000', 'the_rate_limiter_stops_racing_itself'
);

NOTIFY pgrst, 'reload schema';
