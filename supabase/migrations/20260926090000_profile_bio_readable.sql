-- Nobody could see anybody else's biography, and the cause was one column.
--
-- 0003 and 0004 revoked SELECT on public.users wholesale:
--
--     REVOKE SELECT ON public.users FROM anon, authenticated;
--
-- which is the right instinct for a table holding birth dates and recovery
-- material. Since then each public field has been re-granted one at a time —
-- profile_photo_url in 0037, display_name in 20260815224342,
-- profile_banner_url in 20260817100000, and so on.
--
-- connections_count was never among them. And userProfile() reads all of this
-- in a single statement:
--
--     .select('connections_count, display_name, bio, pronouns, deactivated_at')
--
-- Postgres refuses the whole statement when any one column is not granted, so
-- that read fails with 42501 every time, for every profile. Verified against
-- the live database: `select=bio` returns a row, `select=connections_count`
-- returns "42501 permission denied", and the five-column select the app
-- actually issues returns 42501.
--
-- The failure was then swallowed by `catch (_) { }`, which left bio, pronouns,
-- display_name AND the connections count at their defaults with nothing
-- logged. So a person filled in their biography, it saved correctly, and it
-- was invisible to everyone including them on their public profile — with no
-- error anywhere to suggest why.
--
-- WHY GRANTING IS THE RIGHT FIX HERE
--
-- connections_count is already public information: it is rendered on the
-- profile as "4 Connections" next to Vents and Tribes. It is a denormalised
-- counter from 0054, not a private field, and every other column in that same
-- select is already granted. The alternative — moving these fields into
-- user_profile_summary — means editing an RPC that seven migrations have
-- redefined, for no privacy gain.
--
-- Column-scoped, not table-wide. The blanket revoke stays exactly as it is,
-- and this adds precisely one readable counter.

BEGIN;

GRANT SELECT (connections_count) ON public.users TO anon, authenticated;

COMMIT;

SELECT public.record_migration(
  '20260926090000', 'profile_bio_readable'
);

NOTIFY pgrst, 'reload schema';
