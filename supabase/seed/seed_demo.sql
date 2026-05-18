-- ============================================================================
-- Vently | Demo seed data (idempotent)
-- Provides demo users, plugz, posts, comments, and a sample tribe prompt.
-- ============================================================================

BEGIN;

-- Wipe demo rows that previously came from this seed
DELETE FROM moderation_reports WHERE context_data = 'seed';
DELETE FROM chat_messages      WHERE encrypted_payload LIKE 'seed:%';
DELETE FROM chat_rooms         WHERE request_preview LIKE 'seed:%';
DELETE FROM notifications      WHERE payload @> '{"seed": true}'::jsonb;
DELETE FROM prompt_answers     WHERE answer_text LIKE 'seed:%';
DELETE FROM plug_prompts       WHERE prompt_text LIKE 'seed:%';
DELETE FROM comment_likes      WHERE TRUE AND comment_id IN (SELECT comment_id FROM posts_comments WHERE content LIKE 'seed:%');
DELETE FROM posts_comments     WHERE content LIKE 'seed:%';
DELETE FROM post_likes         WHERE TRUE AND post_id IN (SELECT post_id FROM posts WHERE content LIKE 'seed:%');
DELETE FROM posts              WHERE content LIKE 'seed:%';
DELETE FROM tribes_follows     WHERE plug_id IN (SELECT plug_id FROM plug_profiles WHERE display_name IN ('@PatrickO','@HealingCoach','@CampusCircle'));
DELETE FROM plug_profiles      WHERE display_name IN ('@PatrickO','@HealingCoach','@CampusCircle');
DELETE FROM space_memberships  WHERE space_id IN (SELECT space_id FROM spaces WHERE space_name IN ('University of Rwanda','Kigali Institute','Kigali Tech Confessions'));
DELETE FROM spaces             WHERE space_name IN ('University of Rwanda','Kigali Institute','Kigali Tech Confessions');
DELETE FROM users              WHERE anonymous_pseudonym IN (
    'PatrickO','SilentEcho','WanderingSoul','MidnightMind','HiddenFlower',
    'SilentSoul','Ghosty','AnxiousPanda','ChaosDemon','MidnightThinker',
    'HealingCoach','CampusCircle','ShadowWalker','Anonymous291'
);

-- Demo normal users
WITH new_users AS (
    INSERT INTO users(anonymous_pseudonym, avatar_seed, current_mood, recovery_key_hash)
    VALUES
        ('PatrickO',         'patricko-spark',     'hopeful',    'seed-hash-patricko'),
        ('SilentEcho',       'silentecho-orb',     'exhausted',  'seed-hash-silentecho'),
        ('WanderingSoul',    'wanderingsoul-flame','healing',    'seed-hash-wanderingsoul'),
        ('MidnightMind',     'midnightmind-moon',  'overthinking','seed-hash-midnightmind'),
        ('HiddenFlower',     'hiddenflower-petal', 'lonely',     'seed-hash-hiddenflower'),
        ('SilentSoul',       'silentsoul-mist',    'sad',        'seed-hash-silentsoul'),
        ('Ghosty',           'ghosty-vapor',       'confused',   'seed-hash-ghosty'),
        ('AnxiousPanda',     'anxiouspanda-bamboo','anxious',    'seed-hash-anxiouspanda'),
        ('ChaosDemon',       'chaosdemon-bolt',    'angry',      'seed-hash-chaosdemon'),
        ('MidnightThinker',  'midnightthinker-fog','overthinking','seed-hash-midnightthinker'),
        ('ShadowWalker',     'shadowwalker-ash',   'broken',     'seed-hash-shadowwalker'),
        ('Anonymous291',     'anon291-wisp',       'lonely',     'seed-hash-anon291'),
        ('HealingCoach',     'healingcoach-leaf',  'grateful',   'seed-hash-healingcoach'),
        ('CampusCircle',     'campuscircle-spark', 'happy',      'seed-hash-campuscircle')
    RETURNING user_id, anonymous_pseudonym
)
SELECT 1 FROM new_users;

-- Promote PatrickO and HealingCoach to verified Plugz
UPDATE users SET user_role='plug', is_verified=TRUE
WHERE anonymous_pseudonym IN ('PatrickO','HealingCoach','CampusCircle');

INSERT INTO plug_profiles(plug_id, display_name, bio, location_label, tribe_count, approved_at)
SELECT user_id, '@PatrickO',     'Community Keeper | Kigali. Holding space for big feelings.',  'Kigali, Rwanda',  750000, now()
FROM users WHERE anonymous_pseudonym='PatrickO';

INSERT INTO plug_profiles(plug_id, display_name, bio, location_label, tribe_count, approved_at)
SELECT user_id, '@HealingCoach', 'Daily gentle reminders. We rise softly.',                   'Online',          212000, now()
FROM users WHERE anonymous_pseudonym='HealingCoach';

INSERT INTO plug_profiles(plug_id, display_name, bio, location_label, tribe_count, approved_at)
SELECT user_id, '@CampusCircle', 'Kigali Tech Confessions. Vent. Heal. Belong.',              'Kigali, Rwanda',   45000, now()
FROM users WHERE anonymous_pseudonym='CampusCircle';

-- Spaces
INSERT INTO spaces(space_name, space_type, description, domain_validation, member_count)
VALUES
  ('University of Rwanda',     'campus', 'The official emotional sanctuary for UR students.',     'ur.ac.rw', 4209),
  ('Kigali Institute',         'campus', 'Late-night thoughts welcome.',                          'ki.ac.rw', 1200),
  ('Kigali Tech Confessions',  'interest_group', 'Anonymous confessions from the tech scene.',   NULL,        3892);

-- Posts (Confessions category dominates the feed)
INSERT INTO posts(author_id, space_id, category_name, post_type, content, post_mood)
SELECT u.user_id, NULL, 'confessions', 'user_post',
       'seed:Sometimes I feel like I''m giving 100% to everyone around me, but when I need someone, the room is empty. Just needed a safe place to put this thought down before I sleep.',
       'exhausted'
FROM users u WHERE u.anonymous_pseudonym='SilentEcho';

INSERT INTO posts(author_id, space_id, category_name, post_type, content, post_mood)
SELECT u.user_id, NULL, 'healing_corner', 'user_post',
       'seed:Today is the first day in a month that I woke up and didn''t immediately feel a heavy weight on my chest. Progress isn''t linear, but today feels like a win.',
       'healing'
FROM users u WHERE u.anonymous_pseudonym='WanderingSoul';

INSERT INTO posts(author_id, space_id, category_name, post_type, content, post_mood)
SELECT u.user_id, NULL, 'late_night', 'user_post',
       'seed:Why do late nights always bring out the loudest thoughts?',
       'overthinking'
FROM users u WHERE u.anonymous_pseudonym='Anonymous291';

INSERT INTO posts(author_id, space_id, category_name, post_type, content, post_mood)
SELECT u.user_id, s.space_id, 'campus_life', 'user_post',
       'seed:Finals week is draining my soul. Anyone else studying in the library until 2 AM tonight? Bring coffee beans.',
       'exhausted'
FROM users u, spaces s
WHERE u.anonymous_pseudonym='ShadowWalker' AND s.space_name='Kigali Institute';

INSERT INTO posts(author_id, space_id, category_name, post_type, content, post_mood)
SELECT u.user_id, s.space_id, 'campus_life', 'user_post',
       'seed:Just saw the cutest stray dog near the main gate. I gave him half my sandwich. Someone tell me I''m a good person.',
       'happy'
FROM users u, spaces s
WHERE u.anonymous_pseudonym='Anonymous291' AND s.space_name='University of Rwanda';

INSERT INTO posts(author_id, space_id, category_name, post_type, content, post_mood)
SELECT u.user_id, NULL, 'confessions', 'user_post',
       'seed:I accidentally told my boss "love you" before hanging up on a Zoom call. I haven''t spoken to him since and I''m dreading tomorrow morning. Is it time to fake my own death?',
       'anxious'
FROM users u WHERE u.anonymous_pseudonym='MidnightMind';

-- One audio post
INSERT INTO posts(author_id, category_name, post_type, content, post_mood, is_audio, audio_url, audio_duration_ms)
SELECT u.user_id, 'vent_zone', 'user_post',
       'seed:Midnight Thoughts',
       'overthinking', TRUE, 'local://demo/midnight-thoughts.m4a', 130000
FROM users u WHERE u.anonymous_pseudonym='ShadowWalker';

-- Comments thread for the SilentEcho post
DO $$
DECLARE
    post UUID;
    c1 UUID; c2 UUID; c3 UUID; c4 UUID;
    u_ghosty UUID;
    u_anxious UUID;
    u_chaos UUID;
    u_midnightthinker UUID;
BEGIN
    SELECT post_id INTO post FROM posts WHERE content LIKE 'seed:Sometimes I feel like%' LIMIT 1;
    SELECT user_id INTO u_ghosty           FROM users WHERE anonymous_pseudonym='Ghosty';
    SELECT user_id INTO u_anxious          FROM users WHERE anonymous_pseudonym='AnxiousPanda';
    SELECT user_id INTO u_chaos            FROM users WHERE anonymous_pseudonym='ChaosDemon';
    SELECT user_id INTO u_midnightthinker  FROM users WHERE anonymous_pseudonym='MidnightThinker';

    c1 := create_threaded_comment(post, NULL, u_ghosty, 'seed:Bro just own it. Walk in tomorrow with a coffee for him and say "for my favorite person". Assert dominance.');
    c2 := create_threaded_comment(post, c1,   u_anxious, 'seed:Do NOT do this. Just act like it never happened. Pls for your own sanity.');
    c3 := create_threaded_comment(post, c2,   u_chaos,   'seed:Nah the coffee idea is peak Gen Z energy. I support the chaos.');
    c4 := create_threaded_comment(post, NULL, u_midnightthinker, 'seed:I did this to my driving instructor once when I was 17. I failed the test and had to find a new instructor because I couldn''t look him in the eye.');
END $$;

-- Plug prompts
INSERT INTO plug_prompts(plug_id, prompt_text)
SELECT p.plug_id, 'seed:What secrets do you keep from your parents?'
FROM plug_profiles p WHERE p.display_name='@PatrickO';

INSERT INTO plug_prompts(plug_id, prompt_text)
SELECT p.plug_id, 'seed:What''s one kind thing you did for yourself today?'
FROM plug_profiles p WHERE p.display_name='@HealingCoach';

-- Sample tribe follows so PatrickO has visible tribe activity
INSERT INTO tribes_follows(follower_id, plug_id)
SELECT u.user_id, p.plug_id
FROM users u, plug_profiles p
WHERE u.anonymous_pseudonym IN ('SilentEcho','WanderingSoul','MidnightMind','HiddenFlower','SilentSoul')
  AND p.display_name='@PatrickO'
ON CONFLICT DO NOTHING;

-- Sample pending message requests
INSERT INTO chat_rooms(initiated_by, received_by, request_preview, room_status)
SELECT a.user_id, b.user_id, 'seed:I totally get what you mean about the pressure. Would love to chat if you need someone to listen.', 'pending_request'
FROM users a, users b
WHERE a.anonymous_pseudonym='MidnightMind' AND b.anonymous_pseudonym='SilentEcho';

INSERT INTO chat_rooms(initiated_by, received_by, request_preview, room_status)
SELECT a.user_id, b.user_id, 'seed:Hey, your post really resonated with me. Just wanted to say you''re not alone.', 'pending_request'
FROM users a, users b
WHERE a.anonymous_pseudonym='HiddenFlower' AND b.anonymous_pseudonym='SilentEcho';

COMMIT;
