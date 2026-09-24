-- Make "private" mean something, and tell the keeper when somebody knocks.
--
-- request_tribe_membership has always done the right thing: it checks
-- visibility, join_approval_required, minimum_account_age_days, bans and
-- lifecycle, and writes a pending row instead of a membership when approval is
-- needed. None of that was enforcement. It was one function a client could
-- simply not call.
--
-- The policy underneath it, unchanged since 0005, was:
--
--   CREATE POLICY "tribe_members self" ON public.tribe_members FOR ALL
--     USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
--
-- together with GRANT INSERT ON public.tribe_members TO authenticated. A row
-- naming yourself satisfies that check, so one POST to /rest/v1/tribe_members
-- joined any tribe — private, invite-only, approval-required, paused or
-- archived. Confirmed against the local stack: the RPC returned 'pending' and
-- the direct insert put the same user straight in.
--
-- And the policy never constrained `role`, so the insert could say
-- role = 'keeper'. can_manage_tribe() accepts role IN ('keeper','mod'), so it
-- returned true immediately afterwards — which is approve-join-requests,
-- kick-members, edit-rules, transfer-ownership. Also confirmed. That makes
-- this a tribe takeover, not just an unwanted join.
--
-- So: no client writes to tribe_members any more. Every membership change goes
-- through a SECURITY DEFINER function that decides, and the grants are gone.
--
-- Two things fall out of that, both of which were broken anyway:
--
--   * Leaving was already impossible. DELETE was revoked from authenticated in
--     20260816020550 and never re-granted, but the client still deletes
--     directly — so "Leave tribe" has been failing with 42501 in production.
--     leave_tribe() replaces it, and refuses for a keeper, who has to hand the
--     tribe over first. Same rule account deletion already applies.
--
--   * Accepting an invite inserted the membership from the client, so it
--     needed the grant this migration removes. respond_to_tribe_invite() does
--     both halves in one place, and cannot be used to join a tribe you were
--     never invited to.
--
-- Finally, the keeper is told. A pending request produced a number on a
-- dashboard and nothing else — no notification, so the only way to learn
-- somebody was waiting was to go and look.

-- ---------------------------------------------------------------------------
-- 1. Nobody writes their own membership any more.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "tribe_members self" ON public.tribe_members;
DROP POLICY IF EXISTS "tribe_members readable" ON public.tribe_members;
DROP POLICY IF EXISTS "tribe members readable" ON public.tribe_members;

-- Who is in a tribe is not public. A roster is a list of people who have
-- admitted something about themselves by being there, and this app is built
-- for exactly the subjects where that matters. Public tribes stay open, since
-- their whole point is being browsable; for anything else it is the members,
-- the keeper, and staff.
-- The whole test has to live in one SECURITY DEFINER function, because the
-- obvious spelling recurses. A policy on tribe_members that reads tribes
-- triggers the "tribes readable" policy, which itself reads tribe_members to
-- see whether you are a member — so the two policies call each other and
-- Postgres stops it with "infinite recursion detected in policy" on the very
-- first query. Answering the question inside a definer function means neither
-- policy is re-entered.
--
-- plpgsql rather than sql: a plain SQL function can be inlined into the
-- calling query, and an inlined body is planned in the caller's context, which
-- would put the recursion straight back.
CREATE OR REPLACE FUNCTION private.viewer_can_see_roster(p_tribe_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RETURN FALSE; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.tribes AS t
     WHERE t.tribe_id = p_tribe_id
       AND (
         t.visibility = 'public'
         OR t.keeper_id = v_me
         OR EXISTS (
           SELECT 1 FROM public.tribe_members AS m
            WHERE m.tribe_id = p_tribe_id AND m.user_id = v_me
         )
       )
  );
END;
$$;

REVOKE ALL ON FUNCTION private.viewer_can_see_roster(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.viewer_can_see_roster(UUID) TO authenticated;

CREATE POLICY "tribe members readable"
  ON public.tribe_members FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR private.viewer_can_see_roster(tribe_id)
    OR public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin'])
  );

-- No INSERT, UPDATE or DELETE policy at all. The SECURITY DEFINER functions
-- below run as the owner and bypass RLS; everybody else has no route in.
REVOKE INSERT, UPDATE, DELETE ON public.tribe_members FROM authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. Leaving, which has been failing with a permission error.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.leave_tribe(p_tribe_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  -- A tribe without a keeper has nobody who can approve a request, admit a
  -- member or answer a report. Hand it over first.
  IF EXISTS (
    SELECT 1 FROM public.tribes AS t
     WHERE t.tribe_id = p_tribe_id AND t.keeper_id = v_me
  ) THEN
    RAISE EXCEPTION 'keeper_must_transfer_first';
  END IF;

  DELETE FROM public.tribe_members
   WHERE tribe_id = p_tribe_id AND user_id = v_me;

  -- Leaving withdraws a request you had outstanding, so the keeper is not
  -- left deciding about somebody who has walked away.
  UPDATE public.tribe_join_requests
     SET status = 'cancelled', decided_at = pg_catalog.now()
   WHERE tribe_id = p_tribe_id AND user_id = v_me AND status = 'pending';

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_tribe(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.leave_tribe(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Accepting an invite, without a table grant.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.respond_to_tribe_invite(
  p_invite_id UUID,
  p_accept    BOOLEAN
) RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me     UUID := (SELECT auth.uid());
  v_invite public.tribe_invites;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT * INTO v_invite
    FROM public.tribe_invites
   WHERE invite_id = p_invite_id
     FOR UPDATE;

  IF v_invite.invite_id IS NULL THEN RAISE EXCEPTION 'invite_not_found'; END IF;
  -- The invitee, and only the invitee. This is the whole reason the insert
  -- could not stay on the client: it had to be tied to an invite that names
  -- you, and a table grant cannot express that.
  IF v_invite.invited_user_id <> v_me THEN RAISE EXCEPTION 'not_your_invite'; END IF;
  IF v_invite.status <> 'pending' THEN RAISE EXCEPTION 'invite_already_decided'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.tribe_bans AS b
     WHERE b.tribe_id = v_invite.tribe_id AND b.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'member_banned';
  END IF;

  UPDATE public.tribe_invites
     SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END,
         decided_at = pg_catalog.now()
   WHERE invite_id = p_invite_id;

  IF NOT p_accept THEN RETURN 'declined'; END IF;

  INSERT INTO public.tribe_members (tribe_id, user_id, role)
  VALUES (v_invite.tribe_id, v_me, 'member')
  ON CONFLICT DO NOTHING;

  -- An invite accepted settles any request that was outstanding.
  UPDATE public.tribe_join_requests
     SET status = 'approved', decided_at = pg_catalog.now()
   WHERE tribe_id = v_invite.tribe_id AND user_id = v_me AND status = 'pending';

  RETURN 'joined';
END;
$$;

REVOKE ALL ON FUNCTION public.respond_to_tribe_invite(UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_tribe_invite(UUID, BOOLEAN) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. is_private and visibility cannot drift apart.
-- ---------------------------------------------------------------------------
--
-- Two columns saying the same thing, with nothing keeping them equal. Every
-- security decision reads visibility; every badge in the app reads is_private;
-- and admin_create_tribe writes only is_private, so a private tribe created
-- from the admin console came out visibility = 'public' — openly readable and
-- openly joinable while the app drew a padlock on it.
--
-- visibility is the authoritative one, because it is what the policies read
-- and it can say 'invite_only', which a boolean cannot. is_private becomes a
-- mirror of it.

CREATE OR REPLACE FUNCTION private.sync_tribe_visibility()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Whichever one the writer touched, the other follows. If they set both and
  -- disagreed, visibility wins.
  IF TG_OP = 'UPDATE'
     AND NEW.visibility IS NOT DISTINCT FROM OLD.visibility
     AND NEW.is_private IS DISTINCT FROM OLD.is_private THEN
    NEW.visibility := CASE WHEN NEW.is_private THEN 'private' ELSE 'public' END;
  END IF;

  NEW.is_private := NEW.visibility <> 'public';
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.sync_tribe_visibility() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tribes_visibility_sync ON public.tribes;
CREATE TRIGGER tribes_visibility_sync
  BEFORE INSERT OR UPDATE ON public.tribes
  FOR EACH ROW EXECUTE FUNCTION private.sync_tribe_visibility();

-- Anything that had already drifted.
UPDATE public.tribes
   SET is_private = (visibility <> 'public')
 WHERE is_private IS DISTINCT FROM (visibility <> 'public');

-- ---------------------------------------------------------------------------
-- 5. The keeper finds out.
-- ---------------------------------------------------------------------------

-- The whole list, re-stated. The constraint is one expression, so appending is
-- not possible and a partial list silently drops every kind already shipped.
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind::TEXT IN (
    'comment_reply', 'post_like', 'comment_like', 'mention',
    'new_follower', 'friend_request', 'friend_accepted',
    'message_request', 'message_accepted',
    'tribe_prompt', 'tribe_invite', 'tribe_ownership_transfer',
    -- Somebody asked to join a tribe you keep, and the answer is yours.
    'tribe_join_request',
    -- ...and what you decided, told to the person who asked. A request that
    -- vanishes without a word is worse than a refusal.
    'tribe_join_approved', 'tribe_join_declined',
    'whisper_reply', 'whisper_reaction',
    'moderation_action', 'admin_broadcast', 'system',
    'security_alert',
    'security_new_device',
    'security_suspicious_login'
  ));

CREATE OR REPLACE FUNCTION private.notify_tribe_join_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tribe  public.tribes;
  v_who    TEXT;
BEGIN
  -- Fires on a fresh request and on a re-request, since ON CONFLICT flips an
  -- old decision back to pending and the keeper has to see it again.
  IF NEW.status <> 'pending' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' THEN RETURN NEW; END IF;

  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = NEW.tribe_id;
  IF v_tribe.keeper_id IS NULL THEN RETURN NEW; END IF;

  SELECT u.anonymous_pseudonym INTO v_who
    FROM public.users AS u WHERE u.user_id = NEW.user_id;

  INSERT INTO public.notifications (user_id, kind, payload, is_read, actor_id)
  VALUES (
    v_tribe.keeper_id,
    'tribe_join_request',
    jsonb_build_object(
      'title', 'Someone wants to join',
      'body', '@' || COALESCE(v_who, 'Someone') || ' asked to join ' || v_tribe.name,
      'tribe_id', NEW.tribe_id,
      -- The tap target is the members screen, which needs the slug.
      'tribe_slug', v_tribe.slug,
      'request_id', NEW.request_id
    ),
    FALSE,
    NEW.user_id
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.notify_tribe_join_request()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tribe_join_requests_notify ON public.tribe_join_requests;
CREATE TRIGGER tribe_join_requests_notify
  AFTER INSERT OR UPDATE OF status ON public.tribe_join_requests
  FOR EACH ROW EXECUTE FUNCTION private.notify_tribe_join_request();

CREATE OR REPLACE FUNCTION private.notify_tribe_join_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tribe public.tribes;
BEGIN
  IF OLD.status <> 'pending' THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('approved', 'rejected') THEN RETURN NEW; END IF;

  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = NEW.tribe_id;

  INSERT INTO public.notifications (user_id, kind, payload, is_read)
  VALUES (
    NEW.user_id,
    CASE WHEN NEW.status = 'approved'
         THEN 'tribe_join_approved' ELSE 'tribe_join_declined' END,
    jsonb_build_object(
      'title', CASE WHEN NEW.status = 'approved'
                    THEN 'You are in' ELSE 'Not this time' END,
      'body', CASE WHEN NEW.status = 'approved'
                   THEN 'You joined ' || v_tribe.name
                   -- No reason and no keeper named. A declined request is not
                   -- an accusation, and naming who refused invites a reply.
                   ELSE 'Your request to join ' || v_tribe.name
                        || ' was not accepted.' END,
      'tribe_id', NEW.tribe_id,
      'tribe_slug', v_tribe.slug
    ),
    FALSE
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.notify_tribe_join_decision()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tribe_join_requests_decision_notify ON public.tribe_join_requests;
CREATE TRIGGER tribe_join_requests_decision_notify
  AFTER UPDATE OF status ON public.tribe_join_requests
  FOR EACH ROW EXECUTE FUNCTION private.notify_tribe_join_decision();

SELECT public.record_migration(
  '20261045090000', 'private_tribes_are_actually_private'
);

NOTIFY pgrst, 'reload schema';
