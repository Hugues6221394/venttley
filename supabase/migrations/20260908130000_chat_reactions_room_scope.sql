-- Scope chat_message_reactions to room_id so DM realtime can filter WAL
-- events per conversation instead of subscribing to every reaction globally.

ALTER TABLE public.chat_message_reactions
  ADD COLUMN IF NOT EXISTS room_id UUID REFERENCES public.chat_rooms(room_id)
    ON DELETE CASCADE;

UPDATE public.chat_message_reactions AS cr
   SET room_id = m.room_id
  FROM public.chat_messages AS m
 WHERE m.message_id = cr.message_id
   AND cr.room_id IS NULL;

CREATE OR REPLACE FUNCTION public.sync_chat_reaction_room_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.room_id IS NULL THEN
    SELECT m.room_id
      INTO NEW.room_id
      FROM public.chat_messages AS m
     WHERE m.message_id = NEW.message_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_reaction_room_trg ON public.chat_message_reactions;
CREATE TRIGGER chat_reaction_room_trg
  BEFORE INSERT OR UPDATE ON public.chat_message_reactions
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_chat_reaction_room_id();

CREATE INDEX IF NOT EXISTS chat_message_reactions_room_idx
  ON public.chat_message_reactions (room_id);

SELECT public.record_migration(
  '20260908130000', 'chat_reactions_room_scope'
);

NOTIFY pgrst, 'reload schema';
