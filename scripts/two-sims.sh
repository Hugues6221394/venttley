#!/usr/bin/env bash
#
# Start Venttly on two iOS simulators, pointed at the local Supabase stack.
#
#   ./scripts/two-sims.sh
#
# Why a script and not two `flutter run`s: each `flutter run` holds a terminal
# for as long as the app is open, so two of them means two windows you cannot
# close. This builds once and installs the same binary on both, then launches
# them and gets out of the way — the simulators keep running after this exits.
#
# It is a debug build, so it is the real app with the real backend: whatever is
# in the local database is what both phones see, and two simulators means you
# can be two people at once — send a message from one and watch it land on the
# other.
#
# Pass --release to build without the debug overlay and assertions; everything
# else is the same.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE_ID="rw.codafriqa.venttly"
MODE="debug"
TARGET="local"
for arg in "$@"; do
  [[ "$arg" == "--release" ]] && MODE="release"
  [[ "$arg" == "--prod" ]] && TARGET="prod"
done

# ── the backend ────────────────────────────────────────────────────────────
# The simulator shares the Mac's loopback, so 127.0.0.1 reaches the stack
# directly. (An Android emulator would need 10.0.2.2 — it has its own.)
#
# --prod builds against the real project instead. Some things can only be
# tested there: the local stack only advertises email as a sign-in method, so
# Continue with Google hides itself on a local build — the button asks GoTrue
# what is enabled, and locally nothing is. That is a deployment difference,
# not a missing feature, and this flag is how you see it.
if [[ "$TARGET" == "prod" ]]; then
  SUPABASE_URL=""
  SUPABASE_ANON_KEY=""
  echo "▸ building against PRODUCTION (the defaults compiled into the app)"
else
  if ! supabase status >/dev/null 2>&1; then
    echo "▸ local Supabase is not running — starting it"
    supabase start
  fi
  SUPABASE_URL="http://127.0.0.1:54321"
  SUPABASE_ANON_KEY="$(supabase status -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ANON_KEY"])')"
fi

# ── the two phones ─────────────────────────────────────────────────────────
# Whatever is already booted, topped up from the available iPhones if there
# are fewer than two. Booting one that is already booted is not an error, so
# this is safe to run twice.
booted() {
  xcrun simctl list devices booted | grep -oE '\(([0-9A-F-]{36})\) \(Booted\)' \
    | grep -oE '[0-9A-F-]{36}' || true
}

UDIDS=($(booted))
if (( ${#UDIDS[@]} < 2 )); then
  echo "▸ fewer than two simulators booted — starting some"
  CANDIDATES=($(xcrun simctl list devices available \
    | grep -E 'iPhone 1[5-9]' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' | head -4))
  for udid in "${CANDIDATES[@]}"; do
    xcrun simctl boot "$udid" 2>/dev/null || true
    UDIDS=($(booted))
    (( ${#UDIDS[@]} >= 2 )) && break
  done
fi

if (( ${#UDIDS[@]} < 2 )); then
  echo "Could not get two simulators booted. Open Simulator.app and start two"
  echo "iPhones by hand, then run this again."
  exit 1
fi

ONE="${UDIDS[0]}"
TWO="${UDIDS[1]}"
open -a Simulator

# ── build once, install twice ──────────────────────────────────────────────
echo "▸ building ($MODE)"
flutter build ios --simulator "--$MODE" \
  ${SUPABASE_URL:+--dart-define=SUPABASE_URL="$SUPABASE_URL"} \
  ${SUPABASE_ANON_KEY:+--dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"}

APP="build/ios/iphonesimulator/Runner.app"

for udid in "$ONE" "$TWO"; do
  name="$(xcrun simctl list devices | grep "$udid" | sed -E 's/^ *(.*) \(.*/\1/')"
  echo "▸ installing on $name"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP"
  xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
done

echo
echo "Both phones are running against ${SUPABASE_URL:-production}."
echo "Sign in as two different accounts to test anything with two sides to it."
