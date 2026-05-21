-- ============================================================================
-- Venttly | Clear demo seed from a live database
--
-- Removes every row inserted by `seed_demo.sql` (all demo content is tagged
-- with a `seed:` / 'seed' marker or a known pseudonym). Safe to run against
-- production before real users arrive. Idempotent.
--
-- Do NOT run `seed_demo.sql` against production after this — it is for the
-- local dev database / mock backend only.
-- ============================================================================

BEGIN;

DELETE FROM moderation_reports WHERE context_data = 'seed';
DELETE FROM chat_messages      WHERE encrypted_payload LIKE 'seed:%';
DELETE FROM chat_rooms         WHERE request_preview LIKE 'seed:%';
DELETE FROM notifications      WHERE payload @> '{"seed": true}'::jsonb;
DELETE FROM prompt_answers     WHERE answer_text LIKE 'seed:%';
DELETE FROM plug_prompts       WHERE prompt_text LIKE 'seed:%';
DELETE FROM comment_likes      WHERE comment_id IN (
    SELECT comment_id FROM posts_comments WHERE content LIKE 'seed:%');
DELETE FROM posts_comments     WHERE content LIKE 'seed:%';
DELETE FROM post_likes         WHERE post_id IN (
    SELECT post_id FROM posts WHERE content LIKE 'seed:%');
DELETE FROM post_saves         WHERE post_id IN (
    SELECT post_id FROM posts WHERE content LIKE 'seed:%');
DELETE FROM posts              WHERE content LIKE 'seed:%';
DELETE FROM tribes_follows     WHERE plug_id IN (
    SELECT plug_id FROM plug_profiles
    WHERE display_name IN ('@PatrickO', '@HealingCoach', '@CampusCircle'));
DELETE FROM plug_profiles      WHERE display_name IN (
    '@PatrickO', '@HealingCoach', '@CampusCircle');
DELETE FROM space_memberships  WHERE space_id IN (
    SELECT space_id FROM spaces WHERE space_name IN (
        'University of Rwanda', 'Kigali Institute', 'Kigali Tech Confessions'));
DELETE FROM spaces             WHERE space_name IN (
    'University of Rwanda', 'Kigali Institute', 'Kigali Tech Confessions');
DELETE FROM users              WHERE anonymous_pseudonym IN (
    'PatrickO', 'SilentEcho', 'WanderingSoul', 'MidnightMind', 'HiddenFlower',
    'SilentSoul', 'Ghosty', 'AnxiousPanda', 'ChaosDemon', 'MidnightThinker',
    'HealingCoach', 'CampusCircle', 'ShadowWalker', 'Anonymous291');

COMMIT;
