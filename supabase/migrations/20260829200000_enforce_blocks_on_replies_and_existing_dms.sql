-- Blocking, enforced on the surfaces that were still open.
--
-- Venttly enforces blocks well at the moment of *introduction*: friend
-- requests, opening a DM, group invites, feed, and search all check. What none
-- of them cover is a relationship that already exists. Blocking somebody you
-- had been talking to left them able to keep sending into the open thread, and
-- blocking somebody never stopped them replying to your posts at all.
--
-- Both are the same mistake — treating a block as a gate on starting contact
-- rather than a standing condition on having it — and both matter more than
-- the gates that were already closed, because the person you block is usually
-- someone you have already been talking to.
--
-- Enforced by trigger, not by editing the RPCs. Three reasons:
--
--   1. There are six write paths into these three tables (the RPC, an
--      idempotent wrapper around it, and in one case a v2 wrapper around
--      that). Gating each one is five chances to miss one, forever.
--   2. Triggers fire inside SECURITY DEFINER functions. Grants and RLS do not
--      — that is the entire point of a definer function — so a check written
--      as a policy would be bypassed by exactly the code paths that matter.
--   3. It is the precedent. Rate limiting and content safety on these same
--      tables are BEFORE INSERT triggers for the same reason.
--
-- Named block_guard_* so they sort ahead of the existing content_safety_ and
-- guard_ triggers, which fire alphabetically. A rejected write should not
-- consume the sender's rate-limit budget or run the moderation classifier.
--
-- Group rooms are deliberately exempt. A block is between two people; letting
-- it silently break a shared group would leak the block to everyone in it and
-- punish four uninvolved members for one pair's falling-out.

-- ============================================================
-- 1. Replies to a post or a comment
-- ============================================================
-- Symmetric, via has_block: if either party blocked the other, neither writes
-- under the other's name. A one-way check would let the blocker keep replying
-- to someone who can no longer see or answer them, which is worse than either
-- outcome.
CREATE OR REPLACE FUNCTION private.guard_comment_block()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_author   UUID;
  v_parent_author UUID;
BEGIN
  -- No JWT means a cron job, a backfill, or the service role. Those are not
  -- people and cannot block each other.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT p.author_id INTO v_post_author
    FROM public.posts p
   WHERE p.post_id = NEW.post_id;

  IF v_post_author IS NOT NULL
     AND v_post_author <> NEW.author_id
     AND public.has_block(NEW.author_id, v_post_author) THEN
    RAISE EXCEPTION 'blocked_by_user';
  END IF;

  -- A thread can outlive the post author's involvement. Replying directly to
  -- someone who blocked you is the same contact whether or not they wrote the
  -- post it hangs under.
  IF NEW.parent_id IS NOT NULL THEN
    SELECT c.author_id INTO v_parent_author
      FROM public.posts_comments c
     WHERE c.comment_id = NEW.parent_id;

    IF v_parent_author IS NOT NULL
       AND v_parent_author <> NEW.author_id
       AND v_parent_author IS DISTINCT FROM v_post_author
       AND public.has_block(NEW.author_id, v_parent_author) THEN
      RAISE EXCEPTION 'blocked_by_user';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.guard_comment_block()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS block_guard_post_comments ON public.posts_comments;
CREATE TRIGGER block_guard_post_comments
  BEFORE INSERT ON public.posts_comments
  FOR EACH ROW EXECUTE FUNCTION private.guard_comment_block();

-- ============================================================
-- 2. Replies to a whisper
-- ============================================================
CREATE OR REPLACE FUNCTION private.guard_whisper_comment_block()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author        UUID;
  v_parent_author UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT w.author_id INTO v_author
    FROM public.whispers w
   WHERE w.whisper_id = NEW.whisper_id;

  IF v_author IS NOT NULL
     AND v_author <> NEW.author_id
     AND public.has_block(NEW.author_id, v_author) THEN
    RAISE EXCEPTION 'blocked_by_user';
  END IF;

  IF NEW.parent_id IS NOT NULL THEN
    SELECT c.author_id INTO v_parent_author
      FROM public.whisper_comments c
     WHERE c.comment_id = NEW.parent_id;

    IF v_parent_author IS NOT NULL
       AND v_parent_author <> NEW.author_id
       AND v_parent_author IS DISTINCT FROM v_author
       AND public.has_block(NEW.author_id, v_parent_author) THEN
      RAISE EXCEPTION 'blocked_by_user';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.guard_whisper_comment_block()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS block_guard_whisper_comments ON public.whisper_comments;
CREATE TRIGGER block_guard_whisper_comments
  BEFORE INSERT ON public.whisper_comments
  FOR EACH ROW EXECUTE FUNCTION private.guard_whisper_comment_block();

-- ============================================================
-- 3. Messages into a direct room that already exists
-- ============================================================
-- start_chat_room() checks can_dm() before opening a room, so a block stops a
-- new conversation. It never re-checked, so a conversation that predated the
-- block stayed fully open — the single most likely shape for the harassment
-- blocking is supposed to end.
CREATE OR REPLACE FUNCTION private.guard_chat_message_block()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room public.chat_rooms%ROWTYPE;
  v_peer UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_room
    FROM public.chat_rooms r
   WHERE r.room_id = NEW.room_id;

  IF NOT FOUND OR v_room.room_kind IS DISTINCT FROM 'direct' THEN
    RETURN NEW;
  END IF;

  v_peer := CASE
              WHEN v_room.initiated_by = NEW.sender_id THEN v_room.received_by
              ELSE v_room.initiated_by
            END;

  IF v_peer IS NOT NULL
     AND v_peer <> NEW.sender_id
     AND public.has_block(NEW.sender_id, v_peer) THEN
    RAISE EXCEPTION 'blocked_by_user';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.guard_chat_message_block()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS block_guard_chat_messages ON public.chat_messages;
CREATE TRIGGER block_guard_chat_messages
  BEFORE INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION private.guard_chat_message_block();

-- ============================================================
-- 4. An RPC that has not worked since August
-- ============================================================
-- create_threaded_comment is granted to authenticated but is not SECURITY
-- DEFINER, and 20260816020550 revoked INSERT on public tables from that role.
-- Every direct call has therefore failed on privileges since. The app reaches
-- comments through create_threaded_comment_idempotent, which is a definer and
-- calls this one internally as its owner — so that path is unaffected.
--
-- Revoked rather than repaired: making it a definer would open a write path
-- that has been closed for weeks, and adding a second live entry point to
-- commenting is not something to do as a side effect of a blocking fix.
REVOKE EXECUTE ON FUNCTION public.create_threaded_comment(
  UUID, UUID, UUID, TEXT, UUID, TEXT, TEXT
) FROM anon, authenticated;

SELECT public.record_migration(
  '20260829200000',
  'enforce_blocks_on_replies_and_existing_dms'
);

NOTIFY pgrst, 'reload schema';
