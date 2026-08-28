BEGIN;

-- set_post_reaction intentionally runs with an empty search_path. Trigger
-- functions inherit that setting, so the legacy unqualified `UPDATE posts`
-- failed at runtime after the RPC inserted a valid reaction. Fully qualify
-- the counter target and pin the trigger functions' own search path.
CREATE OR REPLACE FUNCTION public.trg_inc_likes()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  UPDATE public.posts
     SET likes_count = likes_count + 1
   WHERE post_id = NEW.post_id;
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION public.trg_dec_likes()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  UPDATE public.posts
     SET likes_count = GREATEST(likes_count - 1, 0)
   WHERE post_id = OLD.post_id;
  RETURN OLD;
END
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
