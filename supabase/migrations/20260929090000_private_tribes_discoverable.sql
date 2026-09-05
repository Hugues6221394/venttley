-- A private Tribe should be findable. Joining it is what should be gated.
--
-- The read policy currently exposes a Tribe to non-members only when it is
-- public:
--
--     (lifecycle_status IN ('active','paused') AND visibility = 'public')
--     OR keeper_id = auth.uid()
--     OR <is a member>
--     OR <is staff>
--
-- so a private Tribe does not exist as far as anybody outside it is concerned:
-- not in search, not in the directory, not in suggestions. The only way in is
-- to already be in. That is not privacy, it is invisibility, and it makes the
-- join-request machinery that already exists — request_tribe_membership and
-- respond_tribe_join_request, both shipped in 20260716175655 — unreachable,
-- because you cannot request to join something you cannot find.
--
-- WHAT THIS DOES AND DOES NOT EXPOSE
--
-- It widens the row, not the room. A private Tribe now appears in search and
-- the directory with what a directory entry is: name, description, category,
-- member count, avatar, and who keeps it. Its CONTENT is unaffected, because
-- content is gated separately by can_read_tribe_content(), which requires
-- public visibility, keepership, or membership — and that function is applied
-- to the posts policy and to the stories query. Verified before making this
-- change rather than assumed: widening the directory would be indefensible if
-- the posts came with it.
--
-- invite_only stays hidden, deliberately. Three visibility values exist and
-- they should mean three different things:
--
--   public       anyone may find it and join it
--   private      anyone may find it, joining needs the Keeper's approval
--   invite_only  you get in by being invited, and it is not advertised
--
-- Collapsing private and invite_only would leave the third option meaningless
-- and would expose Tribes whose keepers chose the most closed setting
-- available.
--
-- 'paused' remains visible alongside 'active' exactly as before; archived and
-- pending-deletion Tribes stay out, which is what 20260924090000 relies on.

BEGIN;

DROP POLICY IF EXISTS "tribes readable" ON public.tribes;
CREATE POLICY "tribes readable"
  ON public.tribes FOR SELECT
  USING (
    (
      lifecycle_status IN ('active', 'paused')
      -- Was: visibility = 'public'. Private Tribes are now discoverable;
      -- their content is not, and their door is still shut.
      AND visibility IN ('public', 'private')
    )
    OR keeper_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.tribe_members m
       WHERE m.tribe_id = tribes.tribe_id AND m.user_id = (SELECT auth.uid())
    )
    OR public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin'])
  );

COMMIT;

SELECT public.record_migration(
  '20260929090000', 'private_tribes_discoverable'
);

NOTIFY pgrst, 'reload schema';
