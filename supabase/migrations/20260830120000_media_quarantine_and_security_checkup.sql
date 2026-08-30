-- Private quarantine for blocked/sensitive media, and a self-only read of
-- when this account last rotated its password.
--
-- Images still land in the public post/whisper buckets first — that is how
-- the existing compose path works. After media-scan returns blocked or
-- sensitive, the service role copies the object here so a later purge of
-- the public object does not destroy the evidence. The bucket is private:
-- no authenticated or anon policy. Service role bypasses RLS.
--
-- password_changed_at is not granted as a column. Other users can SELECT
-- public.users rows, and a last-rotated stamp is not a public profile
-- field. The checkup reads it through a definer that returns only auth.uid().

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'media-quarantine',
    'media-quarantine',
    false,
    10 * 1024 * 1024,
    ARRAY['image/jpeg','image/png','image/webp','image/heic','image/gif']
)
ON CONFLICT (id) DO UPDATE
   SET public             = EXCLUDED.public,
       file_size_limit    = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

-- No storage.objects policies for this bucket. Existing policies are
-- scoped to other bucket ids, so authenticated/anon cannot match a row
-- here. Service role bypasses RLS and is the only writer/reader.

COMMENT ON COLUMN public.users.password_changed_at IS
  'Set by the auth.users password trigger. NULL means never rotated since the column landed. Clients read it only via my_password_changed_at().';

CREATE OR REPLACE FUNCTION public.my_password_changed_at()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT u.password_changed_at
    FROM public.users u
   WHERE u.user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.my_password_changed_at()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_password_changed_at() TO authenticated;

SELECT public.record_migration(
  '20260830120000',
  'media_quarantine_and_security_checkup'
);

NOTIFY pgrst, 'reload schema';
