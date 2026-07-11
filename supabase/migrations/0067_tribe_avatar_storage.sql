-- Tribe avatar uploads land in post-media at tribes/{tribe_id}/…
-- Keepers/mods need INSERT (and upsert UPDATE) beyond the author-owned path rule.

DROP POLICY IF EXISTS "post media tribe manager insert" ON storage.objects;
CREATE POLICY "post media tribe manager insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = 'tribes'
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

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

NOTIFY pgrst, 'reload schema';
