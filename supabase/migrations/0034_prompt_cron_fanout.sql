-- 0034_prompt_cron_fanout.sql
--
-- Background fanout for scheduled prompts. Migration 0028 introduced
-- plug_prompts.scheduled_for + published_at; new prompts authored with
-- a future scheduled_for sit with published_at = NULL until their time.
-- This adds the worker that flips published_at and notifies members.
--
-- Wired entirely inside Postgres via pg_cron — no external worker
-- required. The existing hot-posts cron (migration 0014) confirms the
-- extension is enabled.
--
-- Side effect: a notification row per tribe member, kind = 'tribe_prompt'
-- with the prompt_id + tribe_id in the payload. Caps inserts at the
-- members table snapshot at fanout time so a 10k-member tribe doesn't
-- block the cron — if we ever ship that scale we'll move this to an
-- edge function with paging.

-- ---------------------------------------------------------------------------
-- 0) Backfill: any pre-0028 active prompts that don't yet have a
--    published_at need one so the new "must be published" client
--    filter doesn't suddenly hide them.
-- ---------------------------------------------------------------------------
UPDATE public.plug_prompts
   SET published_at = COALESCE(created_at, now())
 WHERE is_active = true
   AND published_at IS NULL
   AND (scheduled_for IS NULL OR scheduled_for <= now());

-- ---------------------------------------------------------------------------
-- 1) publish_scheduled_prompts() — the fanout worker
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_scheduled_prompts()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT := 0;
    v_row RECORD;
BEGIN
    -- Lock just the due rows so concurrent cron invocations (or manual
    -- calls) don't double-publish.
    FOR v_row IN
        SELECT prompt_id, tribe_id
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
            INSERT INTO notifications (user_id, kind, payload)
            SELECT tm.user_id,
                   'tribe_prompt',
                   jsonb_build_object(
                       'tribe_id',  v_row.tribe_id,
                       'prompt_id', v_row.prompt_id
                   )
              FROM tribe_members tm
             WHERE tm.tribe_id = v_row.tribe_id;
        END IF;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.publish_scheduled_prompts() FROM PUBLIC;
-- Kept inside-Postgres only; nobody outside cron should be calling it.

-- ---------------------------------------------------------------------------
-- 2) Schedule the cron — every minute. Pattern matches the existing
--    refresh_hot_posts_every_2_min job (migration 0014).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_existing INT;
BEGIN
    SELECT jobid INTO v_existing
      FROM cron.job
     WHERE jobname = 'publish_scheduled_prompts_every_minute';
    IF v_existing IS NOT NULL THEN
        PERFORM cron.unschedule(v_existing);
    END IF;
    PERFORM cron.schedule(
        'publish_scheduled_prompts_every_minute',
        '* * * * *',
        $cron$ SELECT public.publish_scheduled_prompts(); $cron$
    );
END $$;
