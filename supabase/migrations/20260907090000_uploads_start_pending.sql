-- Uploaded media starts veiled, not published.
--
-- Found by testing with a real explicit image: it appeared unveiled in the
-- Explore feed. The classifier had worked correctly — the row ended up
-- 'sensitive' with FEMALE_BREAST_EXPOSED at 0.82 — but it was visible before
-- that verdict existed.
--
-- The cause is the column default. 0087 added:
--
--     media_status TEXT NOT NULL DEFAULT 'clean'
--
-- and nothing sets it otherwise on insert. So from the moment a post with an
-- image is created until media-scan flips it, the database says the image is
-- clean, and every feed that loads in that window renders it. The window is
-- seconds, but a feed page fetched inside it is then cached on that device for
-- minutes — which is how a nude image sat unveiled in Explore four minutes
-- after posting.
--
-- No amount of client work fixes this. The client was asking correctly and
-- being told 'clean' by the server.
--
-- WHY A TRIGGER AND NOT A NEW DEFAULT
--
-- Changing the column default to 'pending' would veil text posts too. They
-- have no image, so nothing would render differently, but every text post
-- would sit in a state that says "being checked" when there is nothing to
-- check — and the pending index and the client's polling both key off that.
-- The trigger says the precise thing: media that was uploaded starts pending.
--
-- SCOPED TO OUR OWN STORAGE, DELIBERATELY
--
-- Only media in our buckets is forced to pending, because only that can be
-- scanned. Seed rows pointing at picsum.photos are external URLs media-scan
-- cannot fetch or quarantine; forcing those to pending would veil them
-- permanently with no path to clearing them.
--
-- Existing rows are untouched. This fires on INSERT only, so nothing already
-- published changes state under anybody.

BEGIN;

CREATE OR REPLACE FUNCTION public.force_uploaded_media_pending()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Only ever tightens. If a caller has already said 'sensitive' or 'blocked'
  -- — a re-insert of quarantined content, say — that verdict stands.
  IF NEW.media_status IS DISTINCT FROM 'clean' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'posts' THEN
    -- image_path is set only for uploads into our own bucket, which is exactly
    -- what media-scan can read. image_url alone means an external image.
    IF NEW.image_path IS NOT NULL AND btrim(NEW.image_path) <> '' THEN
      NEW.media_status := 'pending';
    END IF;

  ELSIF TG_TABLE_NAME = 'whispers' THEN
    -- Whispers carry a URL rather than a path, so the bucket is identified
    -- from the URL. An external background is left alone for the same reason
    -- as above: nothing could ever clear it.
    IF NEW.background_image_url IS NOT NULL
       AND NEW.background_image_url LIKE '%/storage/v1/object/%' THEN
      NEW.media_status := 'pending';
    END IF;
  END IF;

  RETURN NEW;
END $$;

COMMENT ON FUNCTION public.force_uploaded_media_pending() IS
  'Uploaded media is veiled on insert until media-scan clears it. Only tightens; never relaxes an existing verdict.';

DROP TRIGGER IF EXISTS posts_uploads_start_pending ON public.posts;
CREATE TRIGGER posts_uploads_start_pending
  BEFORE INSERT ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.force_uploaded_media_pending();

DROP TRIGGER IF EXISTS whispers_uploads_start_pending ON public.whispers;
CREATE TRIGGER whispers_uploads_start_pending
  BEFORE INSERT ON public.whispers
  FOR EACH ROW EXECUTE FUNCTION public.force_uploaded_media_pending();

COMMIT;

SELECT public.record_migration(
  '20260907090000', 'uploads_start_pending'
);

NOTIFY pgrst, 'reload schema';
