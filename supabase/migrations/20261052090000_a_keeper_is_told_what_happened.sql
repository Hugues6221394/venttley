-- A keeper finds out what happened in their tribe.
--
-- Of everything that happens in a tribe, exactly two things reached the person
-- running it: an ownership transfer, and — since 20261045090000 — somebody
-- asking to join. Everything else was a number on a dashboard they had to go
-- and look at, or nothing at all.
--
-- Two more, both of which are somebody else acting on the keeper's tribe
-- rather than the keeper acting:
--
--   tribe_report_filed   — somebody reported a vent in a tribe you keep. This
--                          is the one with a clock on it. A report sitting
--                          unseen is the whole failure mode moderation exists
--                          to prevent.
--
--   tribe_member_joined  — somebody joined. Public tribes only, deliberately:
--                          in a private one the keeper approved the request a
--                          moment earlier, and telling them what they just did
--                          is the kind of noise that teaches people to ignore
--                          a notification list.

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind::TEXT IN (
    'comment_reply', 'post_like', 'comment_like', 'mention',
    'new_follower', 'friend_request', 'friend_accepted',
    'message_request', 'message_accepted',
    'tribe_prompt', 'tribe_invite', 'tribe_ownership_transfer',
    'tribe_join_request', 'tribe_join_approved', 'tribe_join_declined',
    'tribe_report_filed', 'tribe_member_joined',
    'whisper_reply', 'whisper_reaction',
    'moderation_action', 'admin_broadcast', 'system',
    'security_alert', 'security_new_device', 'security_suspicious_login'
  ));

-- ---------------------------------------------------------------------------
-- Somebody reported something in your tribe.
-- ---------------------------------------------------------------------------
--
-- reports carries a post_id and no tribe_id, so the tribe comes through the
-- post. A report against a post that is not in a tribe has no keeper to tell.
CREATE OR REPLACE FUNCTION private.notify_tribe_report()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tribe public.tribes;
BEGIN
  IF NEW.post_id IS NULL THEN RETURN NEW; END IF;

  SELECT t.* INTO v_tribe
    FROM public.posts AS p
    JOIN public.tribes AS t ON t.tribe_id = p.tribe_id
   WHERE p.post_id = NEW.post_id;

  IF v_tribe.keeper_id IS NULL THEN RETURN NEW; END IF;
  -- A keeper reporting something in their own tribe already knows.
  IF v_tribe.keeper_id = NEW.reporter_id THEN RETURN NEW; END IF;

  INSERT INTO public.notifications (user_id, kind, payload, is_read)
  VALUES (
    v_tribe.keeper_id,
    'tribe_report_filed',
    jsonb_build_object(
      'title', 'A vent was reported',
      'body', 'Someone reported a vent in ' || v_tribe.name,
      'tribe_id', v_tribe.tribe_id,
      'tribe_slug', v_tribe.slug,
      'post_id', NEW.post_id
    ),
    FALSE
  );
  -- No actor_id. Who reported something is not the keeper's business, and
  -- putting it in the row would put it one query away from them.
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.notify_tribe_report()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS reports_notify_keeper ON public.reports;
CREATE TRIGGER reports_notify_keeper
  AFTER INSERT ON public.reports
  FOR EACH ROW EXECUTE FUNCTION private.notify_tribe_report();

-- ---------------------------------------------------------------------------
-- Somebody joined.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.notify_tribe_member_joined()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tribe public.tribes;
  v_who   TEXT;
BEGIN
  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = NEW.tribe_id;
  IF v_tribe.keeper_id IS NULL THEN RETURN NEW; END IF;

  -- The keeper's own membership row, written when the tribe is created.
  IF v_tribe.keeper_id = NEW.user_id THEN RETURN NEW; END IF;

  -- Public tribes only. In a private one the keeper approved this a moment
  -- ago, and a notification saying what they just did is how a list becomes
  -- something people stop reading.
  IF v_tribe.visibility <> 'public' THEN RETURN NEW; END IF;

  SELECT u.anonymous_pseudonym INTO v_who
    FROM public.users AS u WHERE u.user_id = NEW.user_id;

  INSERT INTO public.notifications (user_id, kind, payload, is_read, actor_id)
  VALUES (
    v_tribe.keeper_id,
    'tribe_member_joined',
    jsonb_build_object(
      'title', 'Someone joined',
      'body', '@' || COALESCE(v_who, 'Someone') || ' joined ' || v_tribe.name,
      'tribe_id', v_tribe.tribe_id,
      'tribe_slug', v_tribe.slug
    ),
    FALSE,
    NEW.user_id
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.notify_tribe_member_joined()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tribe_members_notify_keeper ON public.tribe_members;
CREATE TRIGGER tribe_members_notify_keeper
  AFTER INSERT ON public.tribe_members
  FOR EACH ROW EXECUTE FUNCTION private.notify_tribe_member_joined();

-- ---------------------------------------------------------------------------
-- The centre itself.
-- ---------------------------------------------------------------------------
--
-- These rows are already addressed to the keeper, so this is a filter rather
-- than a join: the five kinds that only a keeper ever receives, newest first,
-- with the tribe lifted out of the payload so a row can say which tribe it is
-- about without the client parsing JSON.
--
-- Separate from the ordinary notification list on purpose. A keeper running
-- four tribes has a different job from a person catching up on likes, and
-- mixing the two means the thing with a clock on it — a report — sits between
-- two reactions.
CREATE OR REPLACE FUNCTION public.keeper_tribe_notifications(
  p_limit INT DEFAULT 30
) RETURNS TABLE (
  notification_id UUID,
  kind            TEXT,
  title           TEXT,
  body            TEXT,
  tribe_id        UUID,
  tribe_slug      TEXT,
  is_read         BOOLEAN,
  created_at      TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT n.notification_id,
         n.kind::TEXT,
         n.payload->>'title',
         n.payload->>'body',
         (n.payload->>'tribe_id')::UUID,
         n.payload->>'tribe_slug',
         n.is_read,
         n.created_at
    FROM public.notifications AS n
   WHERE n.user_id = (SELECT auth.uid())
     AND n.kind IN (
       'tribe_join_request', 'tribe_report_filed', 'tribe_member_joined',
       'tribe_ownership_transfer', 'tribe_prompt'
     )
   ORDER BY n.created_at DESC
   LIMIT least(greatest(COALESCE(p_limit, 30), 1), 100);
$$;

REVOKE ALL ON FUNCTION public.keeper_tribe_notifications(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.keeper_tribe_notifications(INT) TO authenticated;

-- The badge. One number, so a screen does not have to fetch a list to draw it.
CREATE OR REPLACE FUNCTION public.keeper_unread_notification_count()
RETURNS INT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT count(*)::INT
    FROM public.notifications AS n
   WHERE n.user_id = (SELECT auth.uid())
     AND n.is_read = FALSE
     AND n.kind IN (
       'tribe_join_request', 'tribe_report_filed', 'tribe_member_joined',
       'tribe_ownership_transfer', 'tribe_prompt'
     );
$$;

REVOKE ALL ON FUNCTION public.keeper_unread_notification_count()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.keeper_unread_notification_count()
  TO authenticated;

-- Reading the list is what marks it read, so the badge clears by being looked
-- at rather than by a separate gesture nobody performs.
CREATE OR REPLACE FUNCTION public.mark_keeper_notifications_read()
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_count INT;
BEGIN
  UPDATE public.notifications
     SET is_read = TRUE
   WHERE user_id = (SELECT auth.uid())
     AND is_read = FALSE
     AND kind IN (
       'tribe_join_request', 'tribe_report_filed', 'tribe_member_joined',
       'tribe_ownership_transfer', 'tribe_prompt'
     );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_keeper_notifications_read()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_keeper_notifications_read()
  TO authenticated;

-- Every one of these reads notifications by (user_id, kind) and orders by
-- created_at, and the table only grows.
CREATE INDEX IF NOT EXISTS notifications_user_kind_created_idx
  ON public.notifications (user_id, kind, created_at DESC);

SELECT public.record_migration(
  '20261052090000', 'a_keeper_is_told_what_happened'
);

NOTIFY pgrst, 'reload schema';
