-- The tribe-image storage policy was never broken. It was never deployed.
--
-- 20260928090000 says the tribes/ policy "kept returning 403 … even after that
-- migration was re-applied", concludes with "a policy whose failing clause I
-- could not isolate from outside the database", and moves the client to
-- `<uid>/tribes/<tribeId>/<uuid>.<ext>` — a path the bucket's original 0038
-- owner rule already permits.
--
-- Isolated from inside the database. As the keeper of a Tribe, on a database
-- with 20260928090000 applied:
--
--     SET LOCAL ROLE authenticated;
--     SET LOCAL "request.jwt.claims" = '{"sub":"<keeper>", …}';
--     SELECT public.can_manage_tribe('<tribe>');           -- t
--     INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
--     VALUES ('post-media','tribes/<tribe>/probe.jpg','<keeper>','<keeper>');
--     -- INSERT 0 1
--
-- The insert succeeds. `can_manage_tribe` returns true, is SECURITY DEFINER,
-- and is granted to `authenticated`. There is no failing clause.
--
-- What there is, is a deployment gap. The predecessor
-- `0067_tribe_avatar_storage.sql` never called record_migration — its own
-- re-emission says so — and `20260928090000` is *after* the production
-- boundary: production's last applied migration is 20260828201411, and
-- 20260928090000 > that, so it has never run there. The 403 was a database
-- with no such policy, correctly refusing. The re-application that "did not
-- help" was applied locally; the reproduction was against production.
--
-- The uid-prefixed workaround is therefore load-bearing on production today,
-- and this migration does not break it: the 0038 owner rule stays exactly as
-- it is. The client prefers the stable path and falls back, and the fallback
-- is removable once the migration backlog is applied.
--
-- ---------------------------------------------------------------------------
-- WHY THE PATH SHAPE IS NOW ENFORCED HERE AND NOT ONLY IN DART
-- ---------------------------------------------------------------------------
--
-- The old client minted a fresh `Uuid().v4()` for every upload, so changing a
-- Tribe's picture left the previous object behind forever, with nothing
-- referencing it and nothing to sweep it up. The brief calls this out —
-- "avoid generating uncontrolled duplicate files" — and asks for stable paths
-- of the form `tribes/{tribe_id}/avatar`.
--
-- A stable path is only stable if something enforces it. So these policies now
-- require exactly three segments and a third segment of `avatar` or `banner`
-- (with an optional extension). That makes "one object per image per Tribe" a
-- database invariant rather than a client convention: a replaced image
-- overwrites its predecessor because it cannot be given a different name.
--
-- This *narrows* what 0067 and 20260928090000 allowed. That is safe: the
-- tribes/ prefix has never been writable on production, so no production
-- object has a name this would orphan. If a `tribes/<id>/<uuid>.jpg` object
-- does exist in some environment, it becomes read-only rather than
-- unreadable — the bucket is public and reads are unaffected.
--
-- Replacing an image is an UPDATE (the client upserts to a fixed key), which
-- is why the UPDATE policy matters as much as INSERT. That was the real
-- content of 20260928090000's second half, and it is kept.

BEGIN;

-- ---------------------------------------------------------------------------
-- Path shape
-- ---------------------------------------------------------------------------
-- `tribes/<uuid>/avatar` or `.../banner`, optionally with an extension, and
-- nothing else. IMMUTABLE so it can be used inside a policy predicate.
CREATE OR REPLACE FUNCTION private.is_tribe_image_path(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  -- The extension is restricted to formats the bucket actually accepts, not
  -- just "some short alphanumeric". A permissive `[a-z0-9]{1,5}` let
  -- `avatar.php` through: harmless in practice — Storage serves rather than
  -- executes, and assertSupportedImage would refuse the bytes — but there is
  -- no reason for a public bucket to hold a name like that at all.
  SELECT p_name ~*
    '^tribes/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(avatar|banner)(\.(jpg|jpeg|png|webp|heic|heif|gif))?$';
$$;

COMMENT ON FUNCTION private.is_tribe_image_path(TEXT) IS
  'True for exactly tribes/<tribe uuid>/avatar|banner[.ext]. The regex is the '
  'thing that makes a replaced Tribe image overwrite its predecessor instead '
  'of accumulating one orphan per change.';

-- EXECUTE has to be granted, and this is worth stating because getting it
-- wrong reproduces the original symptom exactly. A policy predicate is
-- evaluated as the *calling* role, so a helper the caller cannot execute
-- makes the whole policy raise:
--
--     ERROR: permission denied for function is_tribe_image_path
--
-- which a storage client surfaces as another opaque 403 on upload. Revoking
-- it here — the reflex for a `private.` helper — broke every tribe image
-- upload until this grant was added, on a database where the policy was
-- otherwise correct. `can_manage_tribe` is granted to `authenticated` for the
-- same reason.
--
-- Nothing leaks: the function takes a string, touches no table, and answers a
-- question the caller already knows the answer to.
REVOKE ALL ON FUNCTION private.is_tribe_image_path(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.is_tribe_image_path(TEXT)
    TO authenticated, anon, service_role;

-- ---------------------------------------------------------------------------
-- The policies, re-emitted with the shape constraint
-- ---------------------------------------------------------------------------
-- DROP-then-CREATE throughout, so this lands in the same state whether the
-- policy was missing, present from 0067, or present from 20260928090000.

DROP POLICY IF EXISTS "post media tribe manager insert" ON storage.objects;
CREATE POLICY "post media tribe manager insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND private.is_tribe_image_path(name)
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

-- Needed because the client upserts to a fixed key: the second and every
-- later upload for a Tribe is an UPDATE, not an INSERT. Without this, setting
-- a picture would work once and then fail forever — a subtler version of the
-- original bug.
DROP POLICY IF EXISTS "post media tribe manager update" ON storage.objects;
CREATE POLICY "post media tribe manager update"
    ON storage.objects FOR UPDATE
    USING (
      bucket_id = 'post-media'
      AND private.is_tribe_image_path(name)
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    )
    WITH CHECK (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND private.is_tribe_image_path(name)
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

-- A SELECT policy, which is not optional even though the bucket is public.
--
-- Public buckets serve reads through the CDN without consulting RLS, so it is
-- tempting to conclude no SELECT policy is needed. But an upsert is an UPDATE,
-- and a row you cannot SELECT is a row an UPDATE cannot find: with only the
-- 0038 owner-read rule (`split_part(name,'/',1) = auth.uid()`), a
-- `tribes/…` object is invisible to its own keeper, and replacing an image
-- silently affected zero rows. Measured: `UPDATE … WHERE name =
-- 'tribes/<id>/avatar.jpg'` reported `UPDATE 0` while the row existed.
--
-- Granted to anon as well, because the bucket is already world-readable and
-- withholding it here would protect nothing while breaking anonymous reads
-- that go through the API rather than the CDN.
DROP POLICY IF EXISTS "post media tribe image read" ON storage.objects;
CREATE POLICY "post media tribe image read"
    ON storage.objects FOR SELECT
    USING (
      bucket_id = 'post-media'
      AND private.is_tribe_image_path(name)
    );

-- Removing a picture deletes the object as well as clearing the column, so a
-- removed image stops being served rather than merely being unreferenced.
--
-- Note that a direct `DELETE FROM storage.objects` is refused by Supabase's
-- own `storage.protect_delete()` trigger regardless of this policy ("Direct
-- deletion from storage tables is not allowed. Use the Storage API instead"),
-- so this is exercised through the Storage API, not SQL.
DROP POLICY IF EXISTS "post media tribe manager delete" ON storage.objects;
CREATE POLICY "post media tribe manager delete"
    ON storage.objects FOR DELETE
    USING (
      bucket_id = 'post-media'
      AND private.is_tribe_image_path(name)
      AND public.can_manage_tribe(split_part(name, '/', 2)::uuid)
    );

COMMIT;

-- Unlike 0067, and unlike whatever state 20260928090000 is in on any given
-- environment, this one is answerable: `SELECT … FROM schema_migrations` now
-- tells you whether the tribe-image policies exist.
SELECT public.record_migration(
  '20261016090000', 'tribe_media_stable_paths'
);

NOTIFY pgrst, 'reload schema';
