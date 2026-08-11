-- Re-derive safety_tier for accounts that predate server-side derivation.
--
-- Until 20260811010000 the tier came from client-supplied signup metadata, so
-- any existing row could be carrying a self-asserted value — including a
-- 13-17 account that declared itself 'standard'. The trigger only fires on new
-- auth users, so those rows stay wrong until corrected here.
--
-- Rows with a NULL birth_year are deliberately LEFT ALONE rather than being
-- swept into the restricted tier. We cannot tell an adult who signed up via
-- Google from a minor who avoided the DOB prompt, and demoting every
-- unknown-age existing account would revoke DM initiation from real adults
-- with no way for them to see why. New unknown-age accounts do fail closed
-- (see the trigger); for existing ones, prompting for a DOB via
-- set_my_birth_year is the honest path and a product decision, not a
-- migration's call to make.

UPDATE public.users AS u
   SET safety_tier = CASE
           WHEN EXTRACT(YEAR FROM now())::INT - u.birth_year <= 17
               THEN 'restricted_minor'
           ELSE 'standard'
       END::safety_tier_type,
       updated_at = now()
 WHERE u.birth_year IS NOT NULL
   AND u.birth_year BETWEEN 1900 AND EXTRACT(YEAR FROM now())::INT
   AND u.safety_tier <> CASE
           WHEN EXTRACT(YEAR FROM now())::INT - u.birth_year <= 17
               THEN 'restricted_minor'
           ELSE 'standard'
       END::safety_tier_type;
