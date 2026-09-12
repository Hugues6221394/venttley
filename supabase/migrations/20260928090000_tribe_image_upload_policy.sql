-- Tribe avatars and banners could not be uploaded at all.
--
-- Reproduced end to end by creating a Tribe with both images attached:
--
--     [ERROR] tribe.media_upload_failed {tribe_id: f6634a18-…, bucket: post-media}
--     StorageException(message: new row violates row-level security policy,
--                      statusCode: 403, error: Unauthorized)
--
-- so every Tribe ever created with images got "Tribe created. Its images could
-- not be saved yet" and a Tribe with no picture.
--
-- WHY IT IS THE TRIBES PATH SPECIFICALLY
--
-- uploadTribeAvatar writes to post-media/tribes/<tribeId>/<uuid>.<ext>. The
-- bucket's original policy from 0038 only permits paths that begin with the
-- uploader's own uid:
--
--     AND split_part(name, '/', 1) = auth.uid()::text
--
-- which a tribes/ path fails. 0067 added the policy that is supposed to cover
-- it, keyed on can_manage_tribe(). Ordinary post and story images upload
-- perfectly well through the uid path — verified, a story image uploaded
-- minutes before this failure — so `owner = auth.uid()` is satisfied and the
-- bucket itself is fine. The gap is only the tribes/ rule.
--
-- 0067 never called record_migration, so there is no way to ask the database
-- whether it was ever applied. Re-emitting it is therefore the honest fix:
-- every statement is DROP-then-CREATE and lands in the same state whether the
-- policy was missing, present, or half-applied.
--
-- The predicate is unchanged from 0067 on purpose. can_manage_tribe() already
-- answers "keeper of this Tribe, or a member with the keeper/mod role", which
-- is exactly who may set its pictures, and it is SECURITY DEFINER so it is not
-- itself subject to the RLS on tribes. Widening this to any authenticated user
-- would let anyone overwrite any Tribe's images.

BEGIN;

DROP POLICY IF EXISTS "post media tribe manager insert" ON storage.objects;
CREATE POLICY "post media tribe manager insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = 'tribes'
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

-- upsert: true on the client means a replaced image is an UPDATE, not an
-- INSERT, so without this the first upload would succeed and every later one
-- would fail — a subtler version of the same bug.
DROP POLICY IF EXISTS "post media tribe manager update" ON storage.objects;
CREATE POLICY "post media tribe manager update"
    ON storage.objects FOR UPDATE
    USING (
      bucket_id = 'post-media'
      AND split_part(name, '/', 1) = 'tribes'
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    )
    WITH CHECK (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = 'tribes'
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

DROP POLICY IF EXISTS "post media tribe manager delete" ON storage.objects;
CREATE POLICY "post media tribe manager delete"
    ON storage.objects FOR DELETE
    USING (
      bucket_id = 'post-media'
      AND split_part(name, '/', 1) = 'tribes'
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

COMMIT;

-- Unlike 0067, say so in the ledger, so the next person can tell.
SELECT public.record_migration(
  '20260928090000', 'tribe_image_upload_policy'
);

NOTIFY pgrst, 'reload schema';
