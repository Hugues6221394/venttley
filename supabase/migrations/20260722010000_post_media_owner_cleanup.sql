-- Let authenticated owners resolve only their own post-media objects.
-- Storage's remove API needs this visibility before the existing owner-only
-- DELETE policy can remove the physical object.
DROP POLICY IF EXISTS "post media owner read" ON storage.objects;
CREATE POLICY "post media owner read"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'post-media'
    AND owner = (SELECT auth.uid())
    AND split_part(name, '/', 1) = (SELECT auth.uid())::text
  );
