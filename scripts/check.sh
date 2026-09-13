#!/usr/bin/env bash
#
# Every layer, in one command.
#
#   ./scripts/check.sh              analyzer + unit + database + device
#   ./scripts/check.sh --fast       skip the device pass
#
# WHY THIS EXISTS
#
# Four suites cover four different things and each was run separately, which
# meant in practice that the slow one was run last or not at all. The slow one
# is the device pass, and it is the one that has caught the most.
#
#   analyzer    types and dead code
#   unit        test/ — logic and widgets against fakes
#   database    supabase/tests/database — pgTAP, real roles, real RLS
#   device      integration_test/ — a real iOS build against a real stack
#
# The device pass is not a formality. Two bugs in the appeals work existed only
# in the seam between a green widget test and a green database test:
#
#   * withAppeal dropped the notification id, so any decision that had ever
#     been appealed lost its appeal route and offered an email address where
#     the button should have been. Invisible to unit tests, whose fixtures
#     build notices directly rather than through the copy.
#   * The action strings the client switched on were invented. The real
#     vocabulary only appeared when a real notify_enforcement row came back
#     over PostgREST; every genuine notice would have rendered unlabelled.
#
# Neither is the kind of thing a mock can tell you, because a mock returns what
# you already believed.

set -uo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; }

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

RC=0
SUMMARY=""
record() { # name, code
  if [ "$2" -eq 0 ]; then SUMMARY="$SUMMARY\n  \033[32mpass\033[0m  $1"
  else SUMMARY="$SUMMARY\n  \033[31mFAIL\033[0m  $1"; RC=1; fi
}

# ---------------------------------------------------------------------------
say "analyzer"
# Only errors and warnings. The deprecation infos are a separate, known piece
# of work and drowning the signal in them is how a real error gets missed.
ISSUES=$(flutter analyze --no-pub lib test integration_test 2>&1 \
         | grep -E "^ +(error|warning)" || true)
if [ -n "$ISSUES" ]; then
  echo "$ISSUES" | head -20
  record "analyzer" 1
else
  ok "  no errors or warnings"
  record "analyzer" 0
fi

# ---------------------------------------------------------------------------
say "unit + widget tests"
flutter test --no-pub 2>&1 | tail -3
record "unit + widget" "${PIPESTATUS[0]}"

# ---------------------------------------------------------------------------
say "database (pgTAP)"
DB=${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
if ! psql "$DB" -tAc 'SELECT 1' >/dev/null 2>&1; then
  fail "  skipped: no local database at $DB. Run: supabase start"
  record "database" 1
else
  TOTAL=0; BAD=0
  for f in supabase/tests/database/*.test.sql; do
    OUT=$(psql "$DB" -tA -f "$f" 2>&1)
    N=$(printf '%s' "$OUT" | grep -cE '^ok [0-9]+' || true)
    TOTAL=$((TOTAL + N))
    # A file that runs fewer assertions than it planned is a failure, not a
    # smaller pass. 0005 aborted mid-file for weeks and reported nothing:
    # the transaction died, the remaining 25 assertions never ran, and the
    # count simply came out lower than anyone was counting.
    if printf '%s' "$OUT" | grep -qE '^not ok|Looks like|^psql.*ERROR'; then
      BAD=$((BAD + 1))
      fail "  $(basename "$f")"
      printf '%s' "$OUT" | grep -E '^not ok|Looks like|ERROR' | head -3
    fi
  done
  echo "  $TOTAL assertions across $(ls supabase/tests/database/*.test.sql | wc -l | tr -d ' ') files"
  record "database ($TOTAL assertions)" "$BAD"
fi

# ---------------------------------------------------------------------------
if [ "$FAST" -eq 1 ]; then
  say "device"
  fail "  skipped (--fast). The seam between the suites above is unverified."
else
  say "device (iOS simulator, live stack)"
  ./scripts/run-integration-tests.sh
  record "device" $?
fi

# ---------------------------------------------------------------------------
printf '\n\033[1m== summary\033[0m'
printf "$SUMMARY\n\n"
[ "$RC" -eq 0 ] && ok "everything passed" || fail "something failed"
exit "$RC"
