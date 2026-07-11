-- ============================================================================
-- 0070: Seed community — real rows so every feature is testable pre-launch.
--
--  * 24 persona users (fixed UUIDs, cannot log in: recovery hash is a stub)
--  * 6 tribes with avatar/banner imagery + General space each
--  * ~40 posts across categories with comments, reactions, some images
--  * 6 whispers (sample audio) + 5 fresh 24h stories
--  * friendships among personas + PENDING friend requests to every real user
--    (accept one and stories/connections light up)
--  * welcome notifications for every real user (badge pipelines fire)
--
-- Idempotent: fixed UUIDs + ON CONFLICT DO NOTHING; safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Persona users  a0000000-0000-4000-8000-0000000000NN
-- ---------------------------------------------------------------------------
INSERT INTO public.users
    (user_id, anonymous_pseudonym, avatar_seed, current_mood, user_role,
     is_verified, safety_tier, birth_year, recovery_key_hash,
     home_city, home_country, profile_photo_url)
VALUES
  ('a0000000-0000-4000-8000-000000000001','MidnightMind','ember-fox','overthinking','normal',false,'standard',2002,'seed-demo','Kigali','Rwanda','https://i.pravatar.cc/300?img=12'),
  ('a0000000-0000-4000-8000-000000000002','QuietStorm','violet-owl','anxious','normal',false,'standard',2003,'seed-demo','Kigali','Rwanda',NULL),
  ('a0000000-0000-4000-8000-000000000003','GoldenHour','sunny-koala','grateful','normal',false,'standard',2001,'seed-demo','Nairobi','Kenya','https://i.pravatar.cc/300?img=32'),
  ('a0000000-0000-4000-8000-000000000004','LostInThought','misty-wolf','confused','normal',false,'standard',2004,'seed-demo','Lagos','Nigeria',NULL),
  ('a0000000-0000-4000-8000-000000000005','BraveHeart22','coral-lion','hopeful','normal',false,'standard',2002,'seed-demo','Accra','Ghana','https://i.pravatar.cc/300?img=47'),
  ('a0000000-0000-4000-8000-000000000006','SilentEcho','pearl-dove','lonely','normal',false,'standard',2005,'seed-demo','Kampala','Uganda',NULL),
  ('a0000000-0000-4000-8000-000000000007','SunsetChaser','amber-deer','happy','normal',false,'standard',2000,'seed-demo','Kigali','Rwanda','https://i.pravatar.cc/300?img=25'),
  ('a0000000-0000-4000-8000-000000000008','BrokenCompass','slate-raven','broken','normal',false,'standard',2003,'seed-demo','Dar es Salaam','Tanzania',NULL),
  ('a0000000-0000-4000-8000-000000000009','HealingSlow','sage-turtle','healing','normal',false,'standard',2001,'seed-demo','Johannesburg','South Africa','https://i.pravatar.cc/300?img=57'),
  ('a0000000-0000-4000-8000-000000000010','NightOwlZee','indigo-owl','exhausted','normal',false,'standard',2004,'seed-demo','Kigali','Rwanda',NULL),
  ('a0000000-0000-4000-8000-000000000011','PaperPlanes','cloud-swan','hopeful','normal',false,'standard',2002,'seed-demo','Nairobi','Kenya','https://i.pravatar.cc/300?img=15'),
  ('a0000000-0000-4000-8000-000000000012','CampusGhost','ash-lynx','overthinking','normal',false,'standard',2005,'seed-demo','Butare','Rwanda',NULL),
  ('a0000000-0000-4000-8000-000000000013','SoftThunder','storm-bear','angry','normal',false,'standard',2000,'seed-demo','Lagos','Nigeria','https://i.pravatar.cc/300?img=68'),
  ('a0000000-0000-4000-8000-000000000014','MorningDew','mint-frog','grateful','normal',false,'standard',2003,'seed-demo','Accra','Ghana',NULL),
  ('a0000000-0000-4000-8000-000000000015','WanderSoul','rose-fawn','confused','normal',false,'standard',2001,'seed-demo','Kigali','Rwanda','https://i.pravatar.cc/300?img=45'),
  ('a0000000-0000-4000-8000-000000000016','InvisibleInk','onyx-cat','sad','normal',false,'standard',2004,'seed-demo','Kampala','Uganda',NULL),
  ('a0000000-0000-4000-8000-000000000017','SecondChance','jade-crane','healing','normal',false,'standard',1999,'seed-demo','Nairobi','Kenya','https://i.pravatar.cc/300?img=36'),
  ('a0000000-0000-4000-8000-000000000018','LateNightTea','plum-moth','overthinking','normal',false,'standard',2002,'seed-demo','Kigali','Rwanda',NULL),
  ('a0000000-0000-4000-8000-000000000019','HopeDealer','gold-finch','hopeful','plug',true,'standard',1998,'seed-demo','Kigali','Rwanda','https://i.pravatar.cc/300?img=8'),
  ('a0000000-0000-4000-8000-000000000020','StillWaters','teal-heron','healing','plug',true,'standard',1999,'seed-demo','Nairobi','Kenya','https://i.pravatar.cc/300?img=20'),
  ('a0000000-0000-4000-8000-000000000021','EchoChamber','ruby-wren','anxious','normal',false,'standard',2005,'seed-demo','Lagos','Nigeria',NULL),
  ('a0000000-0000-4000-8000-000000000022','DawnPatrol','copper-elk','happy','normal',false,'standard',2000,'seed-demo','Kigali','Rwanda','https://i.pravatar.cc/300?img=60'),
  ('a0000000-0000-4000-8000-000000000023','GlassHeart','lilac-moth','broken','normal',false,'standard',2003,'seed-demo','Accra','Ghana',NULL),
  ('a0000000-0000-4000-8000-000000000024','TrueNorth','navy-hawk','grateful','normal',false,'standard',2001,'seed-demo','Kampala','Uganda','https://i.pravatar.cc/300?img=53')
ON CONFLICT (user_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2) Tribes with imagery  b0000000-…  (keepers are personas)
-- ---------------------------------------------------------------------------
INSERT INTO public.tribes
    (tribe_id, name, category, keeper_id, is_private, slug, avatar_url, banner_url)
VALUES
  ('b0000000-0000-4000-8000-000000000001','Midnight Confessions','venting','a0000000-0000-4000-8000-000000000019',false,'midnight-confessions','https://picsum.photos/seed/venttly-mc/300/300','https://picsum.photos/seed/venttly-mc-b/900/300'),
  ('b0000000-0000-4000-8000-000000000002','Campus Life Rwanda','campus','a0000000-0000-4000-8000-000000000020',false,'campus-life-rwanda','https://picsum.photos/seed/venttly-cl/300/300','https://picsum.photos/seed/venttly-cl-b/900/300'),
  ('b0000000-0000-4000-8000-000000000003','Healing Together','support','a0000000-0000-4000-8000-000000000009',false,'healing-together','https://picsum.photos/seed/venttly-ht/300/300','https://picsum.photos/seed/venttly-ht-b/900/300'),
  ('b0000000-0000-4000-8000-000000000004','Dating & Chaos','interest_group','a0000000-0000-4000-8000-000000000007',false,'dating-and-chaos','https://picsum.photos/seed/venttly-dc/300/300','https://picsum.photos/seed/venttly-dc-b/900/300'),
  ('b0000000-0000-4000-8000-000000000005','Faith & Late Nights','support','a0000000-0000-4000-8000-000000000017',false,'faith-late-nights','https://picsum.photos/seed/venttly-fl/300/300','https://picsum.photos/seed/venttly-fl-b/900/300'),
  ('b0000000-0000-4000-8000-000000000006','Hustle & Adulting','hobby','a0000000-0000-4000-8000-000000000013',false,'hustle-adulting','https://picsum.photos/seed/venttly-ha/300/300','https://picsum.photos/seed/venttly-ha-b/900/300')
ON CONFLICT (tribe_id) DO NOTHING;

-- General Space per seeded tribe (mirrors migration 0050's default).
INSERT INTO public.spaces (space_id, tribe_id, slug, name, description, is_default)
SELECT ('c0000000-0000-4000-8000-00000000000' || right(t.tribe_id::text, 1))::uuid,
       t.tribe_id, 'general', 'General', 'The main room — everything goes here.', true
  FROM public.tribes t
 WHERE t.tribe_id::text LIKE 'b0000000-%'
ON CONFLICT (tribe_id, slug) DO NOTHING;

-- Memberships: keepers + a rotating cast per tribe.
INSERT INTO public.tribe_members (tribe_id, user_id)
SELECT t.tribe_id, u.user_id
  FROM public.tribes t
  CROSS JOIN public.users u
 WHERE t.tribe_id::text LIKE 'b0000000-%'
   AND u.user_id::text LIKE 'a0000000-%'
   AND (abs(hashtext(t.tribe_id::text || u.user_id::text)) % 3) < 2
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Posts — confessions/vents across categories, spread over 6 days
-- ---------------------------------------------------------------------------
INSERT INTO public.posts
    (post_id, author_id, tribe_id, space_id, category_name, content, post_mood, image_url, created_at)
SELECT ('d0000000-0000-4000-8000-0000000' || lpad(gs::text, 5, '0'))::uuid,
       ('a0000000-0000-4000-8000-0000000000' || lpad(((gs * 7) % 24 + 1)::text, 2, '0'))::uuid,
       CASE WHEN gs % 3 = 0 THEN ('b0000000-0000-4000-8000-00000000000' || ((gs % 6) + 1)::text)::uuid END,
       CASE WHEN gs % 3 = 0 THEN ('c0000000-0000-4000-8000-00000000000' || ((gs % 6) + 1)::text)::uuid END,
       (ARRAY['confessions','vent_zone','relationships','campus_life','mental_health',
              'funny_confessions','late_night','hot_takes','adulting','friendship',
              'secrets','regrets','dreams_goals','healing_corner','family_issues'])[(gs % 15) + 1],
       (ARRAY[
         'I accidentally told my boss ''love you'' before hanging up a Zoom call. I haven''t spoken to him since. Is it time to fake my own death?',
         'Does anyone else feel like the library is a competitive stress arena? I walked in to study and left with anxiety.',
         'I''ve been pretending to understand my accounting course for a whole semester. Exams are in 3 weeks. Pray for me.',
         'My roommate eats my food and replaces it with apologies. I''m starting a debt ledger.',
         'Today I finally said no to something I didn''t want to do. Small win but I''m proud.',
         'I still check his last-seen every night. I know. I KNOW. Don''t judge me, help me.',
         'The gap between who I am at 9am lectures and who I am at 2am is a whole different person.',
         'Hot take: campus wifi outages have saved more students from bad texts than common sense ever has.',
         'I got the internship!! Six rejections first, but I GOT IT. Never give up fam.',
         'Sometimes I laugh at the perfect moment in a convo and think — maybe I am healing after all.',
         'I moved to a new city for uni and the loneliness hits different at sunset. Anyone else?',
         'Confession: I''ve been the one stealing the good chairs from the study hall. It''s me. I''m the problem.',
         'My mum called just to say she''s proud of me. I cried in a parking lot. 10/10 recommend.',
         'I keep saying ''I''m almost there'' when I haven''t left the house. Adulting is improv.',
         'Failed my driving test for the third time. The examiner said ''see you soon'' like a threat.',
         'To whoever left encouraging sticky notes in the campus toilets — you''re doing God''s work.',
         'I rehearse arguments in the shower and win every time. Undefeated. In reality? 0 wins.',
         'Started therapy last month. Wish someone told me sooner that talking actually helps.',
         'The way my heart drops when I see ''we need to talk''... even from the electricity company.',
         'I''m the friend everyone vents to but nobody checks on. Being strong is exhausting.'
       ])[(gs % 20) + 1],
       (ARRAY['overthinking','anxious','happy','healing','hopeful','exhausted',
              'grateful','confused','lonely','sad'])[(gs % 10) + 1]::mood_badge_type,
       CASE WHEN gs % 6 = 0
            THEN 'https://picsum.photos/seed/venttly-post-' || gs::text || '/800/500' END,
       now() - (gs || ' hours')::interval - ((gs * 13 % 50) || ' minutes')::interval
  FROM generate_series(1, 40) AS gs
ON CONFLICT (post_id) DO NOTHING;

-- 24h stories (whisper-flagged posts, last 12 hours).
INSERT INTO public.posts
    (post_id, author_id, category_name, content, post_mood, is_whisper, image_url, created_at)
SELECT ('d1000000-0000-4000-8000-0000000' || lpad(gs::text, 5, '0'))::uuid,
       ('a0000000-0000-4000-8000-0000000000' || lpad(((gs * 5) % 24 + 1)::text, 2, '0'))::uuid,
       'late_night',
       (ARRAY['Tonight''s mood: grateful and terrified at the same time.',
              '2am thoughts hit different when the playlist agrees with you.',
              'Story time: I waved back at someone who wasn''t waving at me. Transferring universities.',
              'Small win today. Keeping it to myself but also... telling all of you.',
              'If you''re awake reading this — drink water and text them nothing.'])[gs],
       (ARRAY['overthinking','hopeful','lonely','grateful','healing'])[gs]::mood_badge_type,
       true,
       'https://picsum.photos/seed/venttly-story-' || gs::text || '/600/900',
       now() - ((gs * 2) || ' hours')::interval
  FROM generate_series(1, 5) AS gs
ON CONFLICT (post_id) DO NOTHING;

-- Root comments on the first 15 posts (3 each), ltree path = own id.
INSERT INTO public.posts_comments (comment_id, post_id, author_id, content, path, created_at)
SELECT cid, pid, aid, body, text2ltree(replace(cid::text, '-', '_')), ts
FROM (
  SELECT ('e0000000-0000-4000-8000-' || lpad((gs)::text, 12, '0'))::uuid AS cid,
         ('d0000000-0000-4000-8000-0000000' || lpad((((gs - 1) / 3) + 1)::text, 5, '0'))::uuid AS pid,
         ('a0000000-0000-4000-8000-0000000000' || lpad(((gs * 11) % 24 + 1)::text, 2, '0'))::uuid AS aid,
         (ARRAY['Felt this so hard. You''re not alone 🫂',
                'The way this is literally me every single week…',
                'Sending you strength. It gets lighter, I promise.',
                'Nah because why is this so accurate 😭',
                'Proud of you for saying it out loud.',
                'This needs to be framed somewhere.'])[(gs % 6) + 1] AS body,
         now() - ((gs % 40) || ' hours')::interval + '25 minutes'::interval AS ts
    FROM generate_series(1, 45) AS gs
) c
ON CONFLICT (comment_id) DO NOTHING;

-- Reactions: 0–14 per post, rotating across whatever reaction labels the
-- `reaction_type` enum actually holds. Reading the labels from pg_enum keeps
-- this seed working whether or not migration 0052 (the Venttly seven) has run
-- yet — otherwise a DB still on the 0016 set rejects 'hope'/'love'/etc.
DO $$
DECLARE
  labels text[];
BEGIN
  SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO labels
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
   WHERE t.typname = 'reaction_type';

  IF labels IS NULL OR array_length(labels, 1) = 0 THEN
    RAISE NOTICE 'reaction_type enum not found — skipping reaction seed.';
    RETURN;
  END IF;

  INSERT INTO public.post_likes (post_id, user_id, reaction_type)
  SELECT p.post_id,
         u.user_id,
         labels[(abs(hashtext(p.post_id::text || u.user_id::text))
                   % array_length(labels, 1)) + 1]::public.reaction_type
    FROM public.posts p
    CROSS JOIN public.users u
   WHERE p.post_id::text LIKE 'd0000000-%'
     AND u.user_id::text LIKE 'a0000000-%'
     AND (abs(hashtext(u.user_id::text || p.post_id::text)) % 24) < 8
  ON CONFLICT DO NOTHING;
END $$;

-- Make denormalised counters exact regardless of trigger behaviour.
UPDATE public.posts p
   SET likes_count = (SELECT count(*) FROM public.post_likes l WHERE l.post_id = p.post_id),
       comments_count = (SELECT count(*) FROM public.posts_comments c
                          WHERE c.post_id = p.post_id AND c.deleted_at IS NULL)
 WHERE p.post_id::text LIKE 'd0000000-%';

-- ---------------------------------------------------------------------------
-- 4) Whispers — sample audio + imagery
-- ---------------------------------------------------------------------------
INSERT INTO public.whispers
    (whisper_id, author_id, audio_path, audio_url, audio_duration_seconds,
     background_image_url, voice_filter, category_name, title, plays_count, created_at)
SELECT ('f0000000-0000-4000-8000-0000000' || lpad(gs::text, 5, '0'))::uuid,
       ('a0000000-0000-4000-8000-0000000000' || lpad(((gs * 3) % 24 + 1)::text, 2, '0'))::uuid,
       'seed/demo-' || gs::text || '.mp3',
       'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-' || gs::text || '.mp3',
       30 + (gs * 11) % 60,
       'https://picsum.photos/seed/venttly-whisper-' || gs::text || '/600/900',
       (ARRAY['soft','deep_voice','none','echo','anonymous','dark'])[gs],
       (ARRAY['confessions','late_night','healing_corner','relationships','campus_life','secrets'])[gs],
       (ARRAY['3am honesty','The voicemail I never sent','Getting better, slowly',
              'To my almost-person','Finals week survival log','What I never told anyone'])[gs],
       0,  -- real data only: plays_count grows from actual listens (see 0073)
       now() - ((gs * 7) || ' hours')::interval
  FROM generate_series(1, 6) AS gs
ON CONFLICT (whisper_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5) Friendships: personas ↔ personas accepted; personas → real users pending
-- ---------------------------------------------------------------------------
INSERT INTO public.friendships (user_a, user_b, status, requested_by, accepted_at)
SELECT least(a.user_id, b.user_id), greatest(a.user_id, b.user_id),
       'accepted', a.user_id, now() - interval '2 days'
  FROM public.users a
  JOIN public.users b
    ON a.user_id < b.user_id
 WHERE a.user_id::text LIKE 'a0000000-%'
   AND b.user_id::text LIKE 'a0000000-%'
   AND (abs(hashtext(a.user_id::text || b.user_id::text)) % 5) = 0
ON CONFLICT (user_a, user_b) DO NOTHING;

-- Three personas knock on every real account's door (accept to test the
-- full loop: connections count, stories rail, DMs).
INSERT INTO public.friendships (user_a, user_b, status, requested_by)
SELECT least(p.user_id, r.user_id), greatest(p.user_id, r.user_id),
       'pending', p.user_id
  FROM public.users r
  CROSS JOIN (SELECT user_id FROM public.users
               WHERE user_id::text IN
                 ('a0000000-0000-4000-8000-000000000003',
                  'a0000000-0000-4000-8000-000000000009',
                  'a0000000-0000-4000-8000-000000000019')) p
 WHERE r.user_id::text NOT LIKE 'a0000000-%'
ON CONFLICT (user_a, user_b) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6) Welcome notifications for every real user (badges light up)
-- ---------------------------------------------------------------------------
INSERT INTO public.notifications (user_id, kind, payload)
SELECT r.user_id, k.kind, k.payload
  FROM public.users r
  CROSS JOIN (VALUES
    ('new_follower',  '{"message":"GoldenHour sent you a friend request"}'::jsonb),
    ('tribe_prompt',  '{"message":"Midnight Confessions is live — come say hi","tribe_slug":"midnight-confessions"}'::jsonb)
  ) AS k(kind, payload)
 WHERE r.user_id::text NOT LIKE 'a0000000-%'
   AND NOT EXISTS (SELECT 1 FROM public.notifications n
                    WHERE n.user_id = r.user_id AND n.kind = k.kind
                      AND n.payload = k.payload);

-- ---------------------------------------------------------------------------
-- 7) Two member questions (only when migration 0069 has run)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'plug_prompts'
                  AND column_name = 'author_id') THEN
        INSERT INTO public.plug_prompts
            (prompt_id, author_id, prompt_text, audience, is_active, published_at)
        VALUES
          ('99000000-0000-4000-8000-000000000001',
           'a0000000-0000-4000-8000-000000000019',
           'What''s one thing you wish you could tell your younger self before starting uni?',
           'everyone', true, now()),
          ('99000000-0000-4000-8000-000000000002',
           'a0000000-0000-4000-8000-000000000003',
           'What small thing made you smile this week?',
           'everyone', true, now())
        ON CONFLICT (prompt_id) DO NOTHING;
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
