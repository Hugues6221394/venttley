-- 0036_tribe_prompt_payload.sql
--
-- Migration 0034 inserts notifications.kind='tribe_prompt' with a thin
-- payload ({tribe_id, prompt_id}). The mobile notifications screen
-- reads payload.title / payload.body for the tile, so those rows
-- rendered with the raw kind string and no body. This amendment to
-- publish_scheduled_prompts denormalises tribe_name, tribe_slug, and
-- the prompt text into the payload at fanout time — no extra fetches
-- needed on the client.

CREATE OR REPLACE FUNCTION public.publish_scheduled_prompts()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT := 0;
    v_row RECORD;
    v_tribe RECORD;
BEGIN
    FOR v_row IN
        SELECT prompt_id, tribe_id, prompt_text
          FROM plug_prompts
         WHERE scheduled_for IS NOT NULL
           AND scheduled_for <= now()
           AND published_at IS NULL
           AND is_active = true
         FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE plug_prompts
           SET published_at = now()
         WHERE prompt_id = v_row.prompt_id;

        IF v_row.tribe_id IS NOT NULL THEN
            SELECT name, slug INTO v_tribe
              FROM tribes WHERE tribe_id = v_row.tribe_id;

            INSERT INTO notifications (user_id, kind, payload)
            SELECT tm.user_id,
                   'tribe_prompt',
                   jsonb_build_object(
                       'tribe_id',   v_row.tribe_id,
                       'tribe_name', v_tribe.name,
                       'tribe_slug', v_tribe.slug,
                       'prompt_id',  v_row.prompt_id,
                       'title',      'New prompt in ' || v_tribe.name,
                       'body',       left(v_row.prompt_text, 160)
                   )
              FROM tribe_members tm
             WHERE tm.tribe_id = v_row.tribe_id;
        END IF;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.publish_scheduled_prompts() FROM PUBLIC;
