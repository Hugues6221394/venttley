-- The Studio could not state how many members a Tribe has, in any useful
-- breakdown, because membership state is spread across three tables and the
-- stats view only counted one of them.
--
-- WHAT "MEMBER" ACTUALLY MEANS IN THIS SCHEMA
--
-- Worth writing down, because the obvious reading is wrong. `tribe_members`
-- has **no status column**: not active, not pending, not banned. Columns are
-- tribe_id, user_id, joined_at, role, muted_until, warning_count,
-- last_warned_at, member_note, last_seen_at, last_read_at, permissions.
--
-- So the three states live in three places:
--
--   * **active**  — a row in `tribe_members`. Every row is an active
--                   membership; there is no other kind.
--   * **pending** — a row in `tribe_join_requests` with status = 'pending'.
--                   Not a membership at all yet.
--   * **banned**  — a row in `tribe_bans`. Banning removes the membership row
--                   and adds a ban row, so a banned person is not a member
--                   with a flag, they are a non-member with a block. There is
--                   no expiry column: the row's existence is the ban.
--
-- That has a consequence for the KPI block. "Members" and "Active members"
-- are the same number in this schema, and rendering both would put the same
-- value on screen twice under two labels — the exact defect the public-profile
-- work already had to unpick when Connections appeared twice with the same
-- number. So this does not add an `active_members`. It adds
-- `members_active_24h`, which is a genuinely different fact: how many have
-- been *seen* in the last day, from `last_seen_at`, which migration 0063
-- already records and nothing has ever read.
--
-- `members_active_24h` is presence, not membership state. The UI must label it
-- as such ("Active today"), because "Active: 1,193" next to "Members: 1,248"
-- reads as a status breakdown and would invite the question of where the other
-- 55 went.
--
-- WHY THE VIEW AND NOT A NEW RPC
--
-- `tribe_studio_stats` is already the Studio's one read for per-tribe numbers,
-- and `keeper_ai_insights` and `keeper_studio_report` both `SELECT * INTO` it.
-- A parallel RPC would give the Members page a second source that could
-- disagree with the Overview about the same tribe.
--
-- CREATE OR REPLACE, not DROP + CREATE, for that same reason: those two
-- functions depend on this view, and a DROP would either cascade into them or
-- refuse. Replace only permits appending columns, which is all this does — the
-- existing eleven keep their names, types and order.
--
-- The view stays `security_invoker = true`, so these counts are subject to the
-- caller's own RLS. That is correct and load-bearing:
--
--   * `tribe_members` is readable to all (`USING (true)`), so member and
--     moderator counts are honest for anybody.
--   * `tribe_join_requests` is gated on `can_manage_tribe()`, and `tribe_bans`
--     on keeper-or-mod. A non-manager therefore reads 0 pending and 0 banned
--     rather than being refused — the queue size of a Tribe you do not manage
--     is not yours to see, and 0 is the right answer to give a client that
--     should not be asking.
--
-- Which also means: these two columns are only meaningful on the Studio pages,
-- where the caller manages the Tribe. Do not surface them on a public Tribe
-- page and expect a number.

BEGIN;

CREATE OR REPLACE VIEW public.tribe_studio_stats WITH (security_invoker = true) AS
SELECT
    t.tribe_id,
    t.member_count,
    (SELECT count(*) FROM tribe_members tm
      WHERE tm.tribe_id = t.tribe_id
        AND tm.joined_at > now() - interval '7 days')       AS members_7d,
    (SELECT count(*) FROM tribe_members tm
      WHERE tm.tribe_id = t.tribe_id
        AND tm.joined_at > now() - interval '30 days')      AS members_30d,
    (SELECT count(*) FROM posts p
      WHERE p.tribe_id = t.tribe_id
        AND p.deleted_at IS NULL
        AND p.created_at > now() - interval '24 hours')     AS posts_24h,
    (SELECT count(*) FROM posts p
      WHERE p.tribe_id = t.tribe_id
        AND p.deleted_at IS NULL
        AND p.created_at > now() - interval '7 days')       AS posts_7d,
    (SELECT count(*) FROM posts_comments c
      JOIN posts p ON p.post_id = c.post_id
      WHERE p.tribe_id = t.tribe_id
        AND c.created_at > now() - interval '7 days')       AS comments_7d,
    (SELECT count(DISTINCT p.author_id) FROM posts p
      WHERE p.tribe_id = t.tribe_id
        AND p.created_at > now() - interval '7 days')       AS active_posters_7d,
    (SELECT count(*) FROM tribe_pinned_posts pp
      WHERE pp.tribe_id = t.tribe_id)                       AS pinned_count,
    (SELECT count(*) FROM plug_prompts pr
      WHERE pr.tribe_id = t.tribe_id
        AND pr.scheduled_for IS NOT NULL
        AND pr.published_at IS NULL)                        AS scheduled_prompts,
    (SELECT count(*) FROM reports r
      JOIN posts p ON p.post_id = r.post_id
      WHERE p.tribe_id = t.tribe_id
        AND r.is_resolved = false)                          AS open_reports,
    -- ---- appended by 20261009090000 -------------------------------------
    -- Presence, not membership state. See the header.
    (SELECT count(*) FROM tribe_members tm
      WHERE tm.tribe_id = t.tribe_id
        AND tm.last_seen_at > now() - interval '24 hours')   AS members_active_24h,
    (SELECT count(*) FROM tribe_members tm
      WHERE tm.tribe_id = t.tribe_id
        AND tm.role IN ('mod', 'keeper'))                    AS moderator_count,
    -- Not yet members. RLS-gated to tribe managers; 0 for everyone else.
    (SELECT count(*) FROM tribe_join_requests jr
      WHERE jr.tribe_id = t.tribe_id
        AND jr.status = 'pending')                           AS pending_requests,
    -- Former members, blocked from rejoining. Also manager-gated.
    (SELECT count(*) FROM tribe_bans tb
      WHERE tb.tribe_id = t.tribe_id)                        AS banned_count
FROM tribes t;

GRANT SELECT ON public.tribe_studio_stats TO authenticated, anon;

COMMENT ON VIEW public.tribe_studio_stats IS
  'Per-tribe Studio numbers. member_count is the count of tribe_members rows, '
  'which is the only kind of membership there is — pending lives in '
  'tribe_join_requests and banned in tribe_bans. members_active_24h is '
  'presence from last_seen_at, not a membership status. pending_requests and '
  'banned_count are RLS-gated to tribe managers and read 0 for anybody else.';

COMMIT;

SELECT public.record_migration(
  '20261009090000', 'membership_state_kpis'
);

NOTIFY pgrst, 'reload schema';
