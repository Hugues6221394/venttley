#!/usr/bin/env python3
"""Load the opening community into a Venttly database.

    python3 scripts/seed/load.py --db "postgresql://..." \
        --api http://127.0.0.1:54321 --service-key "$SERVICE_ROLE_KEY"

Idempotent: every insert is ON CONFLICT DO NOTHING, so running it twice adds
nothing and breaks nothing.

Counters are NOT written by hand. Posts, likes and comments all go in with the
database's own triggers running, so likes_count and comments_count are whatever
the rows actually say. A seed that sets a comment count directly produces a post
claiming seven replies over an empty comment sheet, which is exactly the bug
this file exists to stop repeating.
"""

import argparse
import hashlib
import json
import random
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from community import PEOPLE          # noqa: E402
from posts_a import POSTS_A           # noqa: E402
from posts_b import POSTS_B           # noqa: E402

POSTS = POSTS_A + POSTS_B
BUCKET = "profile-photos"
# DiceBear's styles are CC0 and illustrated. No real person's photograph is
# presented here as a member of a mental-health community.
AVATAR_STYLE = "notionists"
AVATAR_BG = ["ffd5dc", "ffdfbf", "d1d4f9", "c0aede", "b6e3f4", "ffeaa7"]


def uid(handle: str) -> str:
    """A stable uuid per handle, so a second run updates rather than duplicates."""
    h = hashlib.sha1(f"venttly-seed:{handle}".encode()).hexdigest()
    return f"5eed{h[4:8]}-{h[8:12]}-4{h[13:16]}-8{h[17:20]}-{h[20:32]}"


def post_id(i: int) -> str:
    h = hashlib.sha1(f"venttly-seed-post:{i}".encode()).hexdigest()
    return f"9057{h[4:8]}-{h[8:12]}-4{h[13:16]}-8{h[17:20]}-{h[20:32]}"


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def fetch_avatars(api: str, key: str, out: Path) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    urls = {}
    for i, (_, handle, _, _) in enumerate(PEOPLE):
        png = out / f"{handle}.png"
        if not png.exists():
            src = (
                f"https://api.dicebear.com/9.x/{AVATAR_STYLE}/png"
                f"?seed={handle}&size=256&backgroundColor={AVATAR_BG[i % len(AVATAR_BG)]}"
                f"&backgroundType=solid"
            )
            # curl, not urllib: this machine sits behind a TLS-inspecting
            # proxy whose root urllib does not trust.
            r = subprocess.run(
                ["curl", "-sSL", "--max-time", "30", "-o", str(png), src],
                capture_output=True, text=True,
            )
            if r.returncode != 0 or not png.exists() or png.stat().st_size < 200:
                raise SystemExit(f"could not fetch avatar for {handle}: {r.stderr}")
        path = f"seed/{handle}.png"
        # Retried: forty-five uploads over a mobile link will drop one, and
        # losing the whole run to a single timeout is not worth the simplicity.
        for attempt in range(1, 4):
            up = subprocess.run(
                [
                    "curl", "-sS", "--max-time", "45", "-X", "POST",
                    f"{api}/storage/v1/object/{BUCKET}/{path}",
                    "-H", f"Authorization: Bearer {key}",
                    "-H", "Content-Type: image/png",
                    "-H", "x-upsert: true",
                    "--data-binary", f"@{png}",
                ],
                capture_output=True, text=True,
            )
            body = (up.stdout or "") + (up.stderr or "")
            # "already exists" is the idempotent case, not a failure.
            ok = up.returncode == 0 and not (
                "error" in body.lower() and "exists" not in body.lower()
            )
            if ok:
                break
            if attempt == 3:
                raise SystemExit(f"upload failed for {handle}: {body[:300]}")
        urls[handle] = f"{api}/storage/v1/object/public/{BUCKET}/{path}"
        print(f"  avatar {i + 1}/{len(PEOPLE)} {handle}", end="\r")
    print()
    return urls


def sql_for_people(avatars: dict) -> str:
    rows_auth, rows_user = [], []
    for name, handle, city, bio in PEOPLE:
        u = uid(handle)
        rows_auth.append(
            f"('{u}','00000000-0000-0000-0000-000000000000','authenticated',"
            f"'authenticated','{handle}@id.venttly.app','x',now(),'{{}}','{{}}',"
            f"now() - INTERVAL '8 months', now(),'','','','','','','','')"
        )
        rows_user.append(
            f"('{u}',{q(handle)},{q(handle)},'x',{q(name)},{q(name.lower())},"
            f"{q(handle)},'normal','active',{random.randint(1988, 2004)},"
            f"now() - INTERVAL '8 months',{q(city)},{q(bio)},"
            f"{q(avatars.get(handle, ''))})"
        )
    return f"""
SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token)
VALUES {",".join(rows_auth)}
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
  display_name, display_name_normalized, username_normalized, user_role, account_status,
  birth_year, created_at, home_city, bio, profile_photo_url)
VALUES {",".join(rows_user)}
ON CONFLICT (user_id) DO UPDATE
  SET profile_photo_url = EXCLUDED.profile_photo_url,
      bio = EXCLUDED.bio,
      home_city = EXCLUDED.home_city;

-- Nobody writes anything here without having accepted the current privacy
-- terms; the server guard enforces it on every insert, seeded or not.
INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
 WHERE u.user_id::TEXT LIKE '5eed%'
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;
"""


def sql_chunks(rng: random.Random) -> list:
    handles = [h for _, h, _, _ in PEOPLE]
    chunks = []
    for i, p in enumerate(POSTS):
        out = []
        pid, author = post_id(i), uid(p["a"])
        city = dict((h, c) for _, h, c, _ in PEOPLE)[p["a"]]
        out.append(
            "INSERT INTO public.posts (post_id, author_id, category_name, content, "
            "post_mood, location_bucket, created_at) VALUES "
            f"('{pid}','{author}',{q(p['c'])},{q(p['t'])},"
            f"{q(p['m'])}::public.mood_badge_type,{q(city)},"
            f"now() - INTERVAL '{p['h']} hours') ON CONFLICT (post_id) DO NOTHING;"
        )
        # Likes, weighted so the feed has range rather than a flat 12 each.
        weight = rng.choice([1, 1, 2, 2, 3, 5, 8])
        likers = rng.sample(handles, min(len(handles), 2 + weight * rng.randint(2, 5)))
        for liker in likers:
            if liker == p["a"]:
                continue
            out.append(
                "INSERT INTO public.post_likes (post_id, user_id, created_at) VALUES "
                f"('{pid}','{uid(liker)}', now() - INTERVAL '{max(1, p['h'] - rng.randint(0, 4))} hours') "
                "ON CONFLICT DO NOTHING;"
            )
        # Replies go through the app's own create_threaded_comment, not a
        # straight INSERT: that is what computes the ltree path, recounts the
        # post and files the notification. A reply opening with "@someone" is
        # threaded under that person's reply, the way it reads.
        gap = max(1, p["h"] // (len(p["k"]) + 1))
        for n, (who, text) in enumerate(p["k"], start=1):
            when = max(0, p["h"] - gap * n)
            parent_of = None
            mention = re.match(r"@([a-z0-9_]+)", text)
            if mention and any(mention.group(1) == h for _, h, _, _ in PEOPLE):
                parent_of = uid(mention.group(1))
            parent_sql = (
                f"(SELECT c.comment_id FROM public.posts_comments c "
                f"WHERE c.post_id = '{pid}' AND c.author_id = '{parent_of}' "
                f"ORDER BY c.created_at LIMIT 1)"
            ) if parent_of else "NULL"
            out.append(f"""
DO $seed$
DECLARE v_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM public.posts_comments c
              WHERE c.post_id = '{pid}' AND c.author_id = '{uid(who)}'
                AND c.content = {q(text)}) THEN RETURN; END IF;
  PERFORM set_config('request.jwt.claims',
    '{{"sub":"{uid(who)}","role":"authenticated"}}', FALSE);
  v_id := public.create_threaded_comment(
    '{pid}', {parent_sql}, '{uid(who)}', {q(text)});
  UPDATE public.posts_comments
     SET created_at = now() - INTERVAL '{when} hours'
   WHERE comment_id = v_id;
  PERFORM set_config('request.jwt.claims', '', FALSE);
END $seed$;""")
        chunks.append("\n".join(out))
    return chunks


def run(db: str, sql: str, label: str) -> None:
    print(f"  {label}…", end="\r", flush=True)
    r = subprocess.run(
        ["psql", db, "-v", "ON_ERROR_STOP=1", "-q", "-f", "-"],
        input=sql, text=True, capture_output=True,
    )
    if r.returncode != 0:
        print(r.stderr[-4000:])
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--api", required=True)
    ap.add_argument("--service-key", required=True)
    ap.add_argument("--cache", default="/tmp/venttly-seed-avatars")
    a = ap.parse_args()

    rng = random.Random(20261001)     # fixed, so two runs agree
    print(f"Seeding {len(PEOPLE)} people, {len(POSTS)} posts, "
          f"{sum(len(p['k']) for p in POSTS)} replies")
    avatars = fetch_avatars(a.api, a.service_key, Path(a.cache))
    run(a.db, sql_for_people(avatars), "people")
    # One session per post. A single script with forty posts, twelve hundred
    # likes and a hundred and twenty-seven threaded replies runs long enough
    # that a pooled connection drops out from under it — which it did, halfway.
    chunks = sql_chunks(rng)
    for n, chunk in enumerate(chunks, start=1):
        run(a.db, chunk, f"post {n}/{len(chunks)}")
    print("done")


if __name__ == "__main__":
    main()
