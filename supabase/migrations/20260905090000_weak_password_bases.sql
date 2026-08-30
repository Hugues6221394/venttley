-- Reject passwords that are a guessable word wearing a costume.
--
-- The project already requires twelve characters with lower, upper, digits and
-- symbols, which rejects nearly all of the classic top-ten-thousand on length
-- alone: "password", "123456" and "qwerty" never get near the floor. Adding a
-- list of those would be work that catches almost nothing.
--
-- What the class rules do NOT catch is "Password123!" — twelve characters, all
-- four classes, and among the first things any credential-stuffing list tries.
-- The weakness is not the shape, it is the word underneath it.
--
-- So the check is on the core: lowercase the candidate, drop everything that
-- is not a letter, and see what is left. "Password123!" and "p@ssw0rd!!1" both
-- reduce to "password". "Venttly2026!" reduces to "venttly". A password whose
-- entire alphabetic content is one guessable word is guessable, however many
-- exclamation marks are stapled to the end.
--
-- WHY THE LIST LIVES HERE AND THE CHECK DOES NOT
--
-- The password never reaches this database. Supabase Auth hashes it inside
-- GoTrue; Postgres sees a sealed recovery blob and nothing else. The comparison
-- therefore has to happen on the device, where the plaintext briefly exists,
-- and no amount of wishing makes that server-side.
--
-- That is usually a bad answer — the brief rightly says Flutter validation is
-- only for UX. This one control is the exception, and it is worth being precise
-- about why: the only person who can bypass a weak-password check is the
-- account owner, and the only person harmed is the account owner. Nobody
-- attacks someone else by choosing a weak password themselves. Contrast content
-- moderation, where bypassing the client harms other people, and where
-- client-side enforcement would be worthless.
--
-- Keeping the LIST server-side is what this migration buys: the words can be
-- extended the day a new pattern shows up in the wild, without an app release
-- and without waiting for anybody to update.

BEGIN;

CREATE TABLE IF NOT EXISTS public.weak_password_bases (
  base       TEXT PRIMARY KEY CHECK (base = lower(base) AND base ~ '^[a-z]{3,40}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.weak_password_bases IS
  'Alphabetic cores that make a password guessable regardless of decoration. Public wordlist, not a secret.';

ALTER TABLE public.weak_password_bases ENABLE ROW LEVEL SECURITY;

-- Readable by anyone, including anon: the check runs during sign-up, before
-- there is an account. This is a list of bad passwords, not user data — the
-- only thing it reveals is which words we already refuse.
REVOKE ALL ON public.weak_password_bases FROM PUBLIC;
GRANT SELECT ON public.weak_password_bases TO anon, authenticated;

DROP POLICY IF EXISTS weak_password_bases_read ON public.weak_password_bases;
CREATE POLICY weak_password_bases_read
  ON public.weak_password_bases FOR SELECT TO anon, authenticated USING (TRUE);

INSERT INTO public.weak_password_bases (base) VALUES
  -- The perennials.
  ('password'), ('passwort'), ('passord'), ('motdepasse'), ('contrasena'),
  ('qwerty'), ('qwertyuiop'), ('azerty'), ('asdfgh'), ('zxcvbn'), ('qazwsx'),
  ('letmein'), ('welcome'), ('admin'), ('administrator'), ('root'), ('login'),
  ('secret'), ('changeme'), ('default'), ('guest'), ('test'), ('testing'),
  ('temp'), ('temporary'), ('access'), ('master'), ('superman'), ('batman'),
  ('trustno'), ('whatever'), ('nothing'), ('unknown'), ('freedom'), ('shadow'),
  -- Affection and sentiment, which people reach for on an app like this.
  ('iloveyou'), ('loveme'), ('lovely'), ('sunshine'), ('princess'), ('angel'),
  ('babygirl'), ('babyboy'), ('sweetie'), ('honey'), ('forever'), ('destiny'),
  ('blessed'), ('faith'), ('hope'), ('godisgood'), ('jesus'), ('heaven'),
  -- The app and its context — the first thing anyone tries against a service.
  ('venttly'), ('vently'), ('venttlyapp'), ('rwanda'), ('kigali'),
  ('africa'), ('umuganda'), ('kinyarwanda'),
  -- Keyboard shapes and lazy fillers.
  ('abcdef'), ('abcdefg'), ('abcabc'), ('aaaaaa'), ('asdasd'), ('qweqwe'),
  ('poiuyt'), ('lkjhgf'), ('mnbvcxz'),
  -- Pop culture and sport, heavily represented in every leak corpus.
  ('football'), ('baseball'), ('basketball'), ('soccer'), ('liverpool'),
  ('chelsea'), ('arsenal'), ('barcelona'), ('realmadrid'), ('manutd'),
  ('pokemon'), ('naruto'), ('starwars'), ('marvel'), ('minecraft'),
  -- Self-referential and throwaway.
  ('mypassword'), ('newpassword'), ('mypass'), ('passpass'), ('pass'),
  ('opensesame'), ('iamawesome'), ('nopassword')
ON CONFLICT (base) DO NOTHING;

COMMIT;

SELECT public.record_migration(
  '20260905090000', 'weak_password_bases'
);

NOTIFY pgrst, 'reload schema';
