-- 0049_tribe_rules_and_premium.sql
--
-- Plug dashboard upgrade. Adds three things the manage screen
-- needs and didn't have a home for:
--
--   * rules      — markdown-ish text that the tribe expects
--                  members to follow (shown in the tribe header
--                  and on join).
--   * is_premium — flag the keeper can flip when their tribe is
--                  membership-gated. UI surfaces the badge; the
--                  actual billing wire-up is a follow-up.
--   * settings   — small JSON bag for everything else the
--                  keeper might tweak later (chat slow-mode,
--                  link sharing, etc) without another migration.

ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS rules       TEXT,
    ADD COLUMN IF NOT EXISTS is_premium  BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS settings    JSONB   NOT NULL DEFAULT '{}'::jsonb;

-- Keeper-only mutator. Single RPC to keep the round-trips low
-- when the keeper saves the manage form. NULL arguments mean
-- "leave this field as-is" so partial saves don't blow away
-- other fields.
CREATE OR REPLACE FUNCTION public.update_tribe_management(
    p_tribe_id   UUID,
    p_name       TEXT    DEFAULT NULL,
    p_rules      TEXT    DEFAULT NULL,
    p_is_premium BOOLEAN DEFAULT NULL,
    p_avatar_url TEXT    DEFAULT NULL,
    p_settings   JSONB   DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
BEGIN
    SELECT keeper_id INTO v_keeper
      FROM tribes
     WHERE tribe_id = p_tribe_id;

    IF v_keeper IS NULL THEN
        RAISE EXCEPTION 'tribe_not_found';
    END IF;
    IF v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'not_keeper';
    END IF;

    UPDATE tribes SET
        name       = COALESCE(p_name,       name),
        rules      = COALESCE(p_rules,      rules),
        is_premium = COALESCE(p_is_premium, is_premium),
        avatar_url = COALESCE(p_avatar_url, avatar_url),
        settings   = COALESCE(p_settings,   settings),
        updated_at = now()
    WHERE tribe_id = p_tribe_id;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.update_tribe_management(UUID, TEXT, TEXT, BOOLEAN, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_tribe_management(UUID, TEXT, TEXT, BOOLEAN, TEXT, JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';
