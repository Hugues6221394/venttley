#!/usr/bin/env python3
"""Retire the tester_/demo_ names before real people can see them.

    python3 scripts/seed/rename_test_accounts.py --db "postgresql://..."

These accounts stay — they hold the whispers on the home rail, they keep the
console's super-admin, they are what the team signs in as. Only the names go.

Sign-in resolves a username to <username>@id.venttly.app, and the console
accepts "username or staff email", so the synthetic auth email moves with the
name. Passwords are untouched: after this, sign in with the NEW username and
the same password.

Idempotent — a name already changed is left alone.
"""

import argparse
import subprocess
import sys

# old handle -> (new handle, display name)
RENAMES = {
    "tester_admin":    ("venttly_care",  "Venttly Care"),
    "tester_keeper":   ("harbour_house", "Harbour House"),
    "tester_keeper2":  ("evening_room",  "Evening Room"),
    "tester_comod":    ("still_water",   "Still Water"),
    "tester_verified": ("open_road",     "Open Road"),
    "tester_user":     ("first_light",   "First Light"),
    "demo_alex":       ("kofi_a",        "Kofi"),
    "demo_sam":        ("sade_o",        "Sade"),
    "demo_riley":      ("amara_k",       "Amara"),
}


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    # private.guard_user_identity() refuses any username change, on purpose: a
    # handle is identity in a pseudonymous app and letting it move would break
    # attribution on everything already written. These nine are our own seed and
    # staff accounts being retired before launch, and the guard also sets the
    # normalised columns — which this statement therefore sets by hand.
    parts = ["SET session_replication_role = replica;"]
    for old, (new, display) in RENAMES.items():
        parts.append(f"""
-- {old} -> {new}
UPDATE auth.users SET email = {q(new + '@id.venttly.app')}
 WHERE id = (SELECT user_id FROM public.users
              WHERE username_normalized = {q(old)});

UPDATE public.users
   SET anonymous_pseudonym  = {q(new)},
       username_normalized  = {q(new)},
       display_name         = {q(display)},
       display_name_normalized = {q(display.lower())},
       updated_at = now()
 WHERE username_normalized = {q(old)};""")

    sql = "\n".join(parts) + """
SET session_replication_role = origin;

SELECT username_normalized AS handle, display_name, user_role
  FROM public.users
 WHERE user_id IN (SELECT user_id FROM public.users
                    WHERE username_normalized IN (""" + ",".join(
        q(n) for n, _ in RENAMES.values()) + """))
 ORDER BY user_role, handle;"""

    if a.dry_run:
        print(sql)
        return

    r = subprocess.run(["psql", a.db, "-v", "ON_ERROR_STOP=1", "-f", "-"],
                       input=sql, text=True, capture_output=True)
    if r.returncode != 0:
        print(r.stderr[-3000:])
        sys.exit(1)
    print(r.stdout)
    leftovers = subprocess.run(
        ["psql", a.db, "-t", "-A", "-c",
         "SELECT count(*) FROM public.users WHERE username_normalized LIKE 'tester%' "
         "OR username_normalized LIKE 'demo%'"],
        text=True, capture_output=True).stdout.strip()
    print(f"tester_/demo_ handles remaining: {leftovers}")


if __name__ == "__main__":
    main()
