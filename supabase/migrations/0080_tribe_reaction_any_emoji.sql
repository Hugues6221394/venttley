-- 0080_tribe_reaction_any_emoji.sql
-- Let people react to tribe (chat hub) messages with ANY emoji from their
-- phone keyboard, not just the four preset keys ('same'/'proud'/'tea'/'heart').
-- Drops the whitelist CHECK on the column and the hard-coded IN (...) guard in
-- set_tribe_message_reaction; keeps one-per-user toggle/swap semantics untouched.
-- Legacy rows keep working: the client maps the preset keys to emoji and renders
-- any other stored value as the emoji itself.

-- 1) Relax the column. An emoji can be a multi-codepoint grapheme cluster
--    (skin tones, ZWJ sequences), so allow 1..32 characters instead of a
--    fixed list. Still bounded to stop someone stuffing text in the column.
ALTER TABLE public.tribe_message_reactions
  DROP CONSTRAINT IF EXISTS tribe_message_reactions_emoji_check;
ALTER TABLE public.tribe_message_reactions
  ADD CONSTRAINT tribe_message_reactions_emoji_check
  CHECK (char_length(emoji) BETWEEN 1 AND 32);

-- 2) Function: swap the whitelist for a length/emptiness sanity check.
--    Everything else (membership check, toggle, counts) is identical to 0066.
CREATE OR REPLACE FUNCTION public.set_tribe_message_reaction(
    p_message_id UUID,
    p_emoji      TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_tribe_id UUID;
    v_existing TEXT;
    v_counts JSONB;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    p_emoji := btrim(coalesce(p_emoji, ''));
    IF char_length(p_emoji) = 0 THEN
        RAISE EXCEPTION 'empty reaction';
    END IF;
    IF char_length(p_emoji) > 32 THEN
        RAISE EXCEPTION 'reaction too long';
    END IF;

    SELECT m.tribe_id INTO v_tribe_id
      FROM public.tribe_messages m
     WHERE m.message_id = p_message_id AND m.deleted_at IS NULL;
    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.tribe_members
         WHERE tribe_id = v_tribe_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'not a tribe member';
    END IF;

    SELECT emoji INTO v_existing
      FROM public.tribe_message_reactions
     WHERE message_id = p_message_id AND user_id = v_me;

    IF v_existing = p_emoji THEN
        DELETE FROM public.tribe_message_reactions
         WHERE message_id = p_message_id AND user_id = v_me;
        v_existing := NULL;
    ELSE
        INSERT INTO public.tribe_message_reactions (message_id, user_id, emoji)
        VALUES (p_message_id, v_me, p_emoji)
        ON CONFLICT (message_id, user_id)
        DO UPDATE SET emoji = EXCLUDED.emoji, created_at = now();
        v_existing := p_emoji;
    END IF;

    SELECT COALESCE(jsonb_object_agg(emoji, cnt), '{}'::jsonb)
      INTO v_counts
      FROM (
        SELECT emoji, COUNT(*)::INT AS cnt
          FROM public.tribe_message_reactions
         WHERE message_id = p_message_id
         GROUP BY emoji
      ) s;

    RETURN jsonb_build_object('my_reaction', v_existing, 'reaction_counts', v_counts);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_tribe_message_reaction(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
