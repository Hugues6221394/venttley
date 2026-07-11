-- 0096_fix_member_count.sql
-- Fix stale tribes.member_count (dashboard showed 1 member for a 3-member
-- tribe). The old inc/dec triggers (migration 0005) drift whenever a
-- tribe_members row is added by a path that doesn't fire them cleanly (bulk
-- seeds, historical inserts, ON CONFLICT no-ops). Replace them with a single
-- SELF-HEALING recompute trigger that always sets member_count to the true
-- COUNT(*), then backfill every existing tribe.

CREATE OR REPLACE FUNCTION public.recompute_tribe_member_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_tribe UUID;
BEGIN
    v_tribe := COALESCE(NEW.tribe_id, OLD.tribe_id);
    UPDATE public.tribes
       SET member_count = (
           SELECT count(*) FROM public.tribe_members WHERE tribe_id = v_tribe
       )
     WHERE tribe_id = v_tribe;
    RETURN COALESCE(NEW, OLD);
END $$;

-- Replace the drift-prone increment/decrement triggers with the recompute one.
DROP TRIGGER IF EXISTS tribe_members_inc     ON public.tribe_members;
DROP TRIGGER IF EXISTS tribe_members_dec     ON public.tribe_members;
DROP TRIGGER IF EXISTS tribe_members_recount ON public.tribe_members;
CREATE TRIGGER tribe_members_recount
    AFTER INSERT OR DELETE ON public.tribe_members
    FOR EACH ROW EXECUTE FUNCTION public.recompute_tribe_member_count();

-- One-time backfill: correct every tribe's count to the real number of members.
UPDATE public.tribes t
   SET member_count = (
       SELECT count(*) FROM public.tribe_members tm WHERE tm.tribe_id = t.tribe_id
   );

NOTIFY pgrst, 'reload schema';
