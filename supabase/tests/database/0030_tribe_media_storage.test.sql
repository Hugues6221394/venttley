BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(18);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('bb110000-0000-4000-8000-000000000001','mediakeeper','m','x',
        'mediakeeper','mediakeeper','mediakeeper','normal','active',1995),
       ('bb110000-0000-4000-8000-000000000002','mediamod','m','x',
        'mediamod','mediamod','mediamod','normal','active',1995),
       ('bb110000-0000-4000-8000-000000000003','mediastranger','m','x',
        'mediastranger','mediastranger','mediastranger','normal','active',1995);

INSERT INTO public.tribes (tribe_id, name, slug, category, member_count, is_private, keeper_id)
VALUES ('bb111111-0000-4000-8000-000000000001','Media Probe','media-probe','support',0,false,
        'bb110000-0000-4000-8000-000000000001'),
       ('bb111111-0000-4000-8000-000000000002','Other Tribe','other-probe','support',0,false,
        'bb110000-0000-4000-8000-000000000003');

SET session_replication_role = origin;

INSERT INTO public.tribe_members (tribe_id, user_id, role) VALUES
  ('bb111111-0000-4000-8000-000000000001','bb110000-0000-4000-8000-000000000001','keeper'),
  ('bb111111-0000-4000-8000-000000000001','bb110000-0000-4000-8000-000000000002','mod')
ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = EXCLUDED.role;

-- ---------------------------------------------------------------------------
-- The path shape is the anti-orphan mechanism
-- ---------------------------------------------------------------------------
-- Every uncontrolled-duplicate-file problem in the old client came from being
-- able to choose the object name. These are the names that are now possible.
SELECT ok(
  private.is_tribe_image_path(
    'tribes/bb111111-0000-4000-8000-000000000001/avatar'),
  'a bare avatar path is valid'
);
SELECT ok(
  private.is_tribe_image_path(
    'tribes/bb111111-0000-4000-8000-000000000001/banner.webp'),
  'a banner with a supported extension is valid'
);
SELECT ok(
  private.is_tribe_image_path(
    'tribes/BB111111-0000-4000-8000-000000000001/AVATAR.JPG'),
  'the shape check is case-insensitive, since Storage keys are not normalised'
);
SELECT ok(
  NOT private.is_tribe_image_path(
    'tribes/bb111111-0000-4000-8000-000000000001/9f1e2d3c-uuid.jpg'),
  'a uuid-named object is refused — this is what stopped the orphan-per-upload'
);
SELECT ok(
  NOT private.is_tribe_image_path(
    'tribes/bb111111-0000-4000-8000-000000000001/avatar/nested.jpg'),
  'a nested path is refused'
);
SELECT ok(
  NOT private.is_tribe_image_path('tribes/not-a-uuid/avatar.jpg'),
  'a non-uuid tribe segment is refused'
);
-- Storage serves rather than executes, and the magic-byte check would refuse
-- the payload anyway, but a public bucket has no business holding the name.
SELECT ok(
  NOT private.is_tribe_image_path(
    'tribes/bb111111-0000-4000-8000-000000000001/avatar.php'),
  'a non-image extension is refused'
);
SELECT ok(
  NOT private.is_tribe_image_path(
    'tribes/bb111111-0000-4000-8000-000000000001/avatar.svg'),
  'SVG is refused — it is a script container, not a bitmap'
);

-- The helper has to be executable by the role that evaluates the policy.
-- Revoking it (the reflex for a private. helper) makes every policy using it
-- raise "permission denied for function", which a storage client surfaces as
-- an opaque 403 on upload — indistinguishable from an authorization failure.
SELECT ok(
  has_function_privilege(
    'authenticated', 'private.is_tribe_image_path(text)', 'EXECUTE'),
  'authenticated can execute the path helper, or every policy using it raises'
);

-- ---------------------------------------------------------------------------
-- Who may write a Tribe's images
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"bb110000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
    VALUES ('post-media',
            'tribes/bb111111-0000-4000-8000-000000000001/avatar.jpg',
            'bb110000-0000-4000-8000-000000000001',
            'bb110000-0000-4000-8000-000000000001')$$,
  'the keeper can write their Tribe''s avatar at the stable path'
);

-- Not optional even though the bucket is public: an upsert is an UPDATE, and
-- a row the caller cannot SELECT is a row the UPDATE cannot find. Without a
-- read policy for this prefix, replacing an image silently affected 0 rows.
SELECT is(
  (SELECT count(*)::INT FROM storage.objects
    WHERE bucket_id = 'post-media'
      AND name = 'tribes/bb111111-0000-4000-8000-000000000001/avatar.jpg'),
  1,
  'the keeper can see the object, which is what makes an upsert able to replace it'
);

SELECT lives_ok(
  $$UPDATE storage.objects SET updated_at = now()
     WHERE bucket_id = 'post-media'
       AND name = 'tribes/bb111111-0000-4000-8000-000000000001/avatar.jpg'$$,
  'replacing an image is permitted — the upsert arm of the policy'
);

-- The shape constraint is enforced by the policy, not merely by the client.
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
    VALUES ('post-media',
            'tribes/bb111111-0000-4000-8000-000000000001/9f1e2d3c.jpg',
            'bb110000-0000-4000-8000-000000000001',
            'bb110000-0000-4000-8000-000000000001')$$,
  '42501', NULL,
  'even the keeper cannot create a second, differently-named object'
);

-- A mod manages the Tribe, so a mod may set its pictures. can_manage_tribe()
-- is the single definition of that, shared with every other Tribe surface.
SET LOCAL "request.jwt.claims" =
  '{"sub":"bb110000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
    VALUES ('post-media',
            'tribes/bb111111-0000-4000-8000-000000000001/banner.jpg',
            'bb110000-0000-4000-8000-000000000002',
            'bb110000-0000-4000-8000-000000000002')$$,
  'a moderator of the Tribe can set its banner'
);

-- The property the uid-prefixed workaround could not give: authorization by
-- "do you manage this Tribe", not by "is this your own folder".
SET LOCAL "request.jwt.claims" =
  '{"sub":"bb110000-0000-4000-8000-000000000003","role":"authenticated"}';

SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
    VALUES ('post-media',
            'tribes/bb111111-0000-4000-8000-000000000001/avatar.png',
            'bb110000-0000-4000-8000-000000000003',
            'bb110000-0000-4000-8000-000000000003')$$,
  '42501', NULL,
  'a stranger cannot write another Tribe''s avatar'
);

-- Keeping one Tribe does not grant anything over another.
--
-- Asserted through ROW_COUNT, not as an exception and not with a
-- data-modifying CTE. Two dead ends worth recording: RLS on UPDATE filters
-- through USING rather than raising, so `throws_ok` caught nothing and passed
-- for the wrong reason; and wrapping the UPDATE in a `WITH … RETURNING` used
-- as a scalar subquery is rejected outright ("WITH clause containing a
-- data-modifying statement must be at the top level"), which aborted the
-- whole script mid-plan.
--
-- The read policy is deliberately permissive — the bucket is public, so a
-- stranger *can* see the row. It is writing that is gated.
SELECT lives_ok(
  $probe$
  DO $body$
  DECLARE changed INT;
  BEGIN
    UPDATE storage.objects SET updated_at = now()
     WHERE bucket_id = 'post-media'
       AND name = 'tribes/bb111111-0000-4000-8000-000000000001/avatar.jpg';
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> 0 THEN
      RAISE EXCEPTION 'a non-manager changed % row(s)', changed;
    END IF;
  END $body$;
  $probe$,
  'a keeper of a different Tribe changes no rows on this one''s avatar'
);

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
    VALUES ('post-media',
            'tribes/bb111111-0000-4000-8000-000000000002/avatar.jpg',
            'bb110000-0000-4000-8000-000000000003',
            'bb110000-0000-4000-8000-000000000003')$$,
  'but they can write their own Tribe''s avatar'
);

RESET ROLE;

-- ---------------------------------------------------------------------------
-- The workaround path still works
-- ---------------------------------------------------------------------------
-- 20261016090000 does not touch the 0038 owner rule, deliberately: the
-- uid-prefixed path is load-bearing on production until the migration backlog
-- is applied, and the client falls back to it on a policy refusal.
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"bb110000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name, owner, owner_id)
    VALUES ('post-media',
            'bb110000-0000-4000-8000-000000000001/tribes/x/legacy.jpg',
            'bb110000-0000-4000-8000-000000000001',
            'bb110000-0000-4000-8000-000000000001')$$,
  'the legacy uid-prefixed path is untouched, so the client fallback still works'
);

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
