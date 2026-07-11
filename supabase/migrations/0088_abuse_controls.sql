-- 0088_abuse_controls.sql
-- Anti-abuse controls enforced in the database (can't be bypassed by a
-- modified client):
--   1) SUSPENSION ENFORCEMENT — a suspended/banned user (migration 0085 ladder)
--      genuinely cannot post, comment, or message. Without this the ban is
--      cosmetic.
--   2) VELOCITY LIMITS — per-user rate caps on posts/comments/messages to blunt
--      spam floods and bot activity. Generous enough that normal use never hits
--      them.
--
-- Ban-evasion via fresh anonymous accounts needs a device signal (Play
-- Integrity / App Attest) captured client-side — tracked separately; these
-- server guards make each account's abuse cost real in the meantime.

-- Is this author currently blocked from creating content?
CREATE OR REPLACE FUNCTION public.assert_author_allowed(p_author UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_status TEXT; v_until TIMESTAMPTZ;
BEGIN
    SELECT account_status, suspended_until
      INTO v_status, v_until
      FROM public.users WHERE user_id = p_author;
    IF v_status = 'suspended' AND (v_until IS NULL OR v_until > now()) THEN
        RAISE EXCEPTION 'Your account is suspended.'
            USING errcode = 'check_violation';
    END IF;
END $$;

-- Generic velocity check: how many rows this author created in the window.
CREATE OR REPLACE FUNCTION public.recent_count(
    p_table TEXT, p_author_col TEXT, p_author UUID, p_seconds INT
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
    EXECUTE format(
        'SELECT count(*) FROM public.%I WHERE %I = $1 AND created_at > now() - ($2 || '' seconds'')::interval',
        p_table, p_author_col
    ) INTO v_n USING p_author, p_seconds;
    RETURN v_n;
END $$;

-- ---- posts (max 15 / min) ------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_guard_posts()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    -- Only guard real end-user traffic (PostgREST role). Seeds / migrations /
    -- service-role / admin actions run as other roles and are exempt.
    IF current_user <> 'authenticated' THEN RETURN NEW; END IF;
    IF NEW.author_id IS NOT NULL THEN
        PERFORM public.assert_author_allowed(NEW.author_id);
        IF public.recent_count('posts','author_id',NEW.author_id,60) >= 15 THEN
            RAISE EXCEPTION 'You''re posting too fast — take a breath 💗'
                USING errcode = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_posts ON public.posts;
CREATE TRIGGER guard_posts BEFORE INSERT ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.tg_guard_posts();

-- ---- comments (max 25 / min) --------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_guard_comments()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF current_user <> 'authenticated' THEN RETURN NEW; END IF;
    IF NEW.author_id IS NOT NULL THEN
        PERFORM public.assert_author_allowed(NEW.author_id);
        IF public.recent_count('posts_comments','author_id',NEW.author_id,60) >= 25 THEN
            RAISE EXCEPTION 'You''re commenting too fast — take a breath 💗'
                USING errcode = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_comments ON public.posts_comments;
CREATE TRIGGER guard_comments BEFORE INSERT ON public.posts_comments
    FOR EACH ROW EXECUTE FUNCTION public.tg_guard_comments();

-- ---- DMs (max 40 / min) --------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_guard_chat_messages()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF current_user <> 'authenticated' THEN RETURN NEW; END IF;
    IF NEW.sender_id IS NOT NULL THEN
        PERFORM public.assert_author_allowed(NEW.sender_id);
        IF public.recent_count('chat_messages','sender_id',NEW.sender_id,60) >= 40 THEN
            RAISE EXCEPTION 'Slow down a little 💗'
                USING errcode = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_chat_messages ON public.chat_messages;
CREATE TRIGGER guard_chat_messages BEFORE INSERT ON public.chat_messages
    FOR EACH ROW EXECUTE FUNCTION public.tg_guard_chat_messages();

-- ---- tribe messages (max 40 / min) --------------------------------------
CREATE OR REPLACE FUNCTION public.tg_guard_tribe_messages()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF current_user <> 'authenticated' THEN RETURN NEW; END IF;
    IF NEW.sender_id IS NOT NULL THEN
        PERFORM public.assert_author_allowed(NEW.sender_id);
        IF public.recent_count('tribe_messages','sender_id',NEW.sender_id,60) >= 40 THEN
            RAISE EXCEPTION 'Slow down a little 💗'
                USING errcode = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_tribe_messages ON public.tribe_messages;
CREATE TRIGGER guard_tribe_messages BEFORE INSERT ON public.tribe_messages
    FOR EACH ROW EXECUTE FUNCTION public.tg_guard_tribe_messages();

NOTIFY pgrst, 'reload schema';
