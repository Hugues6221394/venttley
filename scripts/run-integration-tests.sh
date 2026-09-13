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

SIM=${SIM:-$(xcrun simctl list devices booted \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)}
if [ -z "$SIM" ]; then
  fail "No booted simulator. Boot one first:"
  fail "  xcrun simctl boot <device-id> && open -a Simulator"
  exit 1
fi
echo "simulator: $SIM"

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

say "done"
[ "$RC" -eq 0 ] && echo "  all integration tests passed" || fail "  some integration tests failed or were skipped"
exit "$RC"
