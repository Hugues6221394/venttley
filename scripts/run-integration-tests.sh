#!/usr/bin/env bash
#
# Integration tests, on a booted iOS simulator.
#
#   ./scripts/run-integration-tests.sh
#
# WHY THIS EXISTS
#
# `flutter test` only scans test/. Nothing runs integration_test/ unless
# someone remembers to, and the two files there need different and
# non-obvious --dart-define flags. The result was that
# identity_music_smoke_test had been failing for a long time and nobody knew:
# without --dart-define=USE_MOCK_BACKEND=true the app's provider graph reaches
# Supabase before the mock can stand in, and the test dies on
# "You must initialize the supabase instance". It was never broken. It was
# never run correctly.
#
# The two files want opposite things, which is the whole reason a single
# command could not cover them:
#
#   identity_music_smoke_test   mock backend, no network, drives real widgets
#   realtime_propagation_test   live stack, real auth, real websocket
#
# The realtime one needs `supabase start` and the seeded test accounts.

set -uo pipefail

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; }

BOOTED=$(xcrun simctl list devices booted | grep -c Booted || true)
SIM=${SIM:-$(xcrun simctl list devices booted \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)}
if [ -z "$SIM" ]; then
  fail "No booted simulator. Boot one first:"
  fail "  xcrun simctl boot <device-id> && open -a Simulator"
  exit 1
fi
# Named, not just a UDID. With more than one simulator booted the choice is
# arbitrary, and a result attributed to the wrong device is worse than no
# result — "it passed on the simulator" has to mean a specific one.
SIM_NAME=$(xcrun simctl list devices booted | grep "$SIM" | sed -E 's/^ *//; s/ *\(.*//')
echo "simulator: ${SIM_NAME:-unknown} ($SIM)"
if [ "${BOOTED:-1}" -gt 1 ]; then
  echo "  note: $BOOTED simulators are booted; this run uses the one above."
  echo "        Pick another with: SIM=<device-id> $0"
fi

RC=0

say "identity + music smoke test (mock backend)"
# USE_MOCK_BACKEND is mandatory here. Without it the app resolves the live
# Supabase backend and the test fails for a reason that has nothing to do with
# what it is checking.
flutter test integration_test/identity_music_smoke_test.dart \
  -d "$SIM" --no-pub --dart-define=USE_MOCK_BACKEND=true || RC=1

say "realtime propagation (live local stack)"
URL=${SUPABASE_URL:-http://127.0.0.1:54321}
KEY=${SUPABASE_ANON_KEY:-}
if [ -z "$KEY" ]; then
  KEY=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY=//p' | tr -d '"')
fi
if [ -z "$KEY" ]; then
  fail "  skipped: no anon key. Start the stack (supabase start) or export SUPABASE_ANON_KEY."
  RC=1
elif ! curl -s -o /dev/null --max-time 5 "$URL/rest/v1/" -H "apikey: $KEY"; then
  fail "  skipped: $URL is not answering. Run: supabase start"
  RC=1
elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q realtime; then
  # Worth its own message: without the realtime container the test fails on a
  # subscribe timeout, which reads like a product bug and is not one.
  fail "  skipped: the realtime container is not running, so this test would"
  fail "           time out waiting to subscribe. Run: supabase start"
  RC=1
else
  flutter test integration_test/realtime_propagation_test.dart \
    -d "$SIM" --no-pub \
    --dart-define=SUPABASE_URL="$URL" \
    --dart-define=SUPABASE_ANON_KEY="$KEY" || RC=1
fi

say "like button on a real device (live local stack)"
if [ -z "$KEY" ]; then
  fail "  skipped: no anon key. Run: supabase start"
  RC=1
elif ! curl -s -o /dev/null --max-time 5 "$URL/rest/v1/" -H "apikey: $KEY"; then
  fail "  skipped: $URL is not answering. Run: supabase start"
  RC=1
else
  flutter test integration_test/like_button_test.dart \
    -d "$SIM" --no-pub \
    --dart-define=SUPABASE_URL="$URL" \
    --dart-define=SUPABASE_ANON_KEY="$KEY" || RC=1
fi

say "appeals end to end (live local stack)"
# No realtime dependency here, so it is gated only on the stack answering.
if [ -z "$KEY" ]; then
  fail "  skipped: no anon key. Run: supabase start"
  RC=1
elif ! curl -s -o /dev/null --max-time 5 "$URL/rest/v1/" -H "apikey: $KEY"; then
  fail "  skipped: $URL is not answering. Run: supabase start"
  RC=1
else
  # Passes with a clean record too, but says so rather than reporting a green
  # run that never reached the write path. To exercise that path there has to
  # be an appealable decision against tester_user.
  flutter test integration_test/appeals_flow_test.dart \
    -d "$SIM" --no-pub \
    --dart-define=SUPABASE_URL="$URL" \
    --dart-define=SUPABASE_ANON_KEY="$KEY" || RC=1
fi

say "coverage"
# The failure this script was written to prevent, one level up: a file lands in
# integration_test/ and nothing runs it, so it passes review and then never
# executes again. like_button_test.dart sat unrun for exactly that reason.
# Every file has to be named above, with the flags it needs — there is no
# generic invocation that works for all of them, which is the whole problem.
MISSING=""
for f in integration_test/*.dart; do
  grep -q "$(basename "$f")" "$0" || MISSING="$MISSING $(basename "$f")"
done
if [ -n "$MISSING" ]; then
  fail "  these integration tests are not run by this script:$MISSING"
  fail "  add them above with the dart-defines they need, or they will never run"
  RC=1
else
  echo "  every file in integration_test/ is run by this script"
fi

say "done"
[ "$RC" -eq 0 ] && echo "  all integration tests passed" || fail "  some integration tests failed or were skipped"
exit "$RC"
