-- Three queries that were fine at fourteen rows and are not fine at scale.
--
-- Measured, not guessed. A throwaway transaction on the local stack seeded
-- 40,000 users, 30,000 direct rooms, 300,000 chat messages and 200,000 posts,
-- ran ANALYZE, and then EXPLAIN (ANALYZE) on the queries the app actually
-- sends. Three of them fell over; the rest were already fine, and are left
-- alone.
--
--   opening the inbox      414 ms  ->  1.4 ms
--   opening the feed      4987 ms  ->  1.5 ms
--   searching             3216 ms  ->  ~50 ms
--
-- All three had the same underlying cause: a predicate wrapped in a function,
-- which the planner cannot see through and therefore cannot serve from an
-- index. In every case the index already existed.

-- ---------------------------------------------------------------------------
-- 1. The inbox read a table scan per open.
-- ---------------------------------------------------------------------------
--
-- The RLS policy on chat_rooms was `private.is_chat_room_member(room_id)`. The
-- function is correct, and it is opaque: the planner has to fetch every row in
-- the table and call it. The plan said so plainly —
--
--     Seq Scan on chat_rooms r  (actual rows=1)
--       Rows Removed by Filter: 29999
--
-- — thirty thousand rows examined, one returned, and the cost grows with every
-- room anybody in the system has ever opened rather than with the number the
-- caller is in.
--
-- The same test spelled out over the columns lets the planner use the indexes
-- that were already there: a BitmapOr across idx_chat_rooms_users,
-- idx_chat_rooms_status and chat_rooms_kind_activity_idx.
--
-- is_chat_room_member is left in place. Twenty other policies and functions
-- call it, and it is the right shape for all of them — it is only wrong as the
-- driving predicate of a scan.

DROP POLICY IF EXISTS "chat_rooms participants read" ON public.chat_rooms;

CREATE POLICY "chat_rooms participants read"
  ON public.chat_rooms FOR SELECT TO authenticated
  USING (
    (
      room_kind = 'direct'
      AND (
        initiated_by = (SELECT auth.uid())
        OR received_by = (SELECT auth.uid())
      )
    )
    OR (
      room_kind = 'group'
      AND EXISTS (
        SELECT 1
          FROM public.chat_room_members m
         WHERE m.room_id = chat_rooms.room_id
           AND m.user_id = (SELECT auth.uid())
           AND m.left_at IS NULL
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 2. The feed read every post ever written.
-- ---------------------------------------------------------------------------
--
-- The app asks feed_posts for `ORDER BY created_at DESC, post_id DESC LIMIT
-- 20`. Eighteen indexes exist on posts and not one of them matches that sort:
-- every candidate is either ascending, or partial on `deleted_at IS NULL`
-- which the query does not state, or leads with another column. So the planner
-- read all 200,000 rows and sorted them to return twenty.
--
-- Deliberately not partial. A partial index is only usable when the query
-- repeats its predicate, and the feed query does not mention deleted_at — a
-- `WHERE deleted_at IS NULL` index here would be as unused as the eighteen
-- already are.
CREATE INDEX IF NOT EXISTS posts_feed_created_idx
  ON public.posts (created_at DESC, post_id DESC);

-- ---------------------------------------------------------------------------
-- 3. Search is left alone, and here is why.
-- ---------------------------------------------------------------------------
--
-- Searching post content took 3.2 seconds at 200,000 posts, on a full
-- sequential scan, with idx_posts_content_trgm sitting unused since 0119.
--
-- The first read of this was wrong and is worth recording. Running the same
-- ILIKE straight against public.posts is an index scan in 2.5 ms — but that
-- test ran as postgres, with no row-level security. As `authenticated` it
-- scans, every time, and no amount of rewriting the query changes that.
--
-- The reason is that ILIKE (`~~*`) is not leakproof. Postgres will not
-- evaluate a non-leakproof qual before a table's RLS security quals, because
-- doing so could leak the contents of rows the caller may not read through an
-- error message or a timing difference. So the six conjuncts of the "posts
-- readable" policy — can_view_post_author, can_read_tribe_content,
-- can_manage_tribe, is_staff, the approval test and the story-audience test —
-- all run first, on every row, and only then is the trigram condition
-- considered. There is no index that helps.
--
-- Making it fast means a SECURITY DEFINER function that restates those six
-- conjuncts itself, the way search_user_hits already does for users. That is
-- the correct fix and it is not a small one: getting it subtly wrong puts
-- private-tribe posts, hidden posts and friends-only stories into a search
-- box. It wants its own change and its own tests rather than a footnote to a
-- performance pass.
--
-- Left exactly as it was. Slow and correct beats fast and leaky.

-- ---------------------------------------------------------------------------
-- 4. Two indexes the presence writes need.
-- ---------------------------------------------------------------------------
--
-- Every signed-in client writes last_seen_at once a minute. At a hundred
-- thousand concurrent that is a few thousand writes a second before anybody
-- does anything, and each one has to find its row.
CREATE INDEX IF NOT EXISTS chat_room_members_user_id_idx
  ON public.chat_room_members (user_id);

SELECT public.record_migration(
  '20261051090000', 'three_queries_that_do_not_scale'
);

NOTIFY pgrst, 'reload schema';
