#!/usr/bin/env bash
#
# Build a store-ready artefact.
#
#   ./scripts/release.sh android        AAB for Play Console
#   ./scripts/release.sh ios            IPA for App Store Connect
#   ./scripts/release.sh android --bump increment the build number first
#
# WHY THIS EXISTS
#
# `flutter build appbundle` succeeds in situations that get you rejected, and
# the failure arrives days later as an email. It signs with debug keys if the
# keystore is absent. It packages the working directory, not a commit, so a
# half-finished edit ships. It reuses a build number the store has already
# seen. It does not care that google-services.json is registered to a different
# package than the one it is building, so push silently never works.
#
# So the checks come first, every time, and the environment is an argument
# rather than a default -- the same reason scripts/deploy.sh takes one.
#
# WHAT THIS DOES NOT DO
#
# Upload. Deliberately. The first submission of an app involves decisions --
# age rating, privacy answers, export compliance, which build is the one -- that
# should be made by a person looking at the console, not inherited from a
# script's defaults. Once the first release is through and the shape is known,
# uploading is a two-line addition here.

set -uo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; }
die()  { fail "$1"; exit 1; }

TARGET="${1:-}"
BUMP=0
[ "${2:-}" = "--bump" ] && BUMP=1

case "$TARGET" in
  android|ios) ;;
  *) die "Usage: $0 android|ios [--bump]" ;;
esac

# ---------------------------------------------------------------------------
say "readiness"
# ---------------------------------------------------------------------------

node scripts/check-release-readiness.mjs || die "fix the blockers above first"

# ---------------------------------------------------------------------------
# The build number. Play refuses a versionCode it has already accepted and App
# Store Connect refuses a build number it has already accepted; both are silent
# until the upload is rejected, which is the slowest possible place to learn it.
# ---------------------------------------------------------------------------

VERSION=$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')
SEMVER="${VERSION%%+*}"
BUILD="${VERSION##*+}"

if [ "$BUMP" -eq 1 ]; then
  NEXT=$((BUILD + 1))
  # macOS sed needs the empty -i argument; GNU sed does not accept it.
  sed -i '' "s/^version: .*/version: ${SEMVER}+${NEXT}/" pubspec.yaml \
    || die "could not update pubspec.yaml"
  BUILD="$NEXT"
  ok "  build number -> ${SEMVER}+${BUILD} (commit this)"
else
  printf '  version %s+%s (pass --bump to increment)\n' "$SEMVER" "$BUILD"
fi

# ---------------------------------------------------------------------------
say "tests"
# ---------------------------------------------------------------------------

flutter analyze --no-fatal-infos > /tmp/venttly-release-analyze.log 2>&1
ERRORS=$(grep -cE '^\s+error' /tmp/venttly-release-analyze.log || true)
if [ "${ERRORS:-0}" -gt 0 ]; then
  grep -E '^\s+error' /tmp/venttly-release-analyze.log | head -10
  die "analyzer reported ${ERRORS} error(s)"
fi
ok "  analyzer clean"

if ! flutter test > /tmp/venttly-release-test.log 2>&1; then
  tail -20 /tmp/venttly-release-test.log
  fail "  unit tests failed"
  printf '  Continue anyway? Type yes to build a release with failing tests: '
  read -r CONFIRM
  [ "$CONFIRM" = "yes" ] || exit 1
else
  ok "  unit tests passed"
fi

# ---------------------------------------------------------------------------
say "build ($TARGET)"
# ---------------------------------------------------------------------------

if [ "$TARGET" = "android" ]; then
  [ -f android/key.properties ] || die \
"android/key.properties is missing, so this would be signed with debug keys and
Play would refuse it.

Create the upload keystore once, and never lose it -- Play ties the app to this
key permanently, and losing it means losing the ability to update the app:

  keytool -genkey -v -keystore ~/venttly-upload-keystore.jks \\
    -keyalg RSA -keysize 2048 -validity 10000 -alias venttly

Then write android/key.properties (it is gitignored):

  storeFile=/Users/<you>/venttly-upload-keystore.jks
  storePassword=<the password you just chose>
  keyAlias=venttly
  keyPassword=<the same password unless you chose another>

Back up the .jks file somewhere that survives this laptop."

  flutter build appbundle --release || die "appbundle build failed"
  ARTEFACT="build/app/outputs/bundle/release/app-release.aab"
  [ -f "$ARTEFACT" ] || die "expected $ARTEFACT, which is not there"

  # A debug-signed bundle is the failure this script exists to catch, and it is
  # invisible until Play rejects it.
  if command -v keytool >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    if unzip -l "$ARTEFACT" 2>/dev/null | grep -q "META-INF/"; then
      ok "  bundle is signed"
    else
      fail "  bundle appears unsigned"
    fi
  fi

  ok "  $ARTEFACT ($(du -h "$ARTEFACT" | cut -f1))"
  printf '\n  Upload at https://play.google.com/console → Venttly → Production → Create new release\n'
fi

if [ "$TARGET" = "ios" ]; then
  if ! xcrun security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution\|iPhone Distribution"; then
    die \
"No Apple distribution certificate on this machine, so there is nothing to sign
with. That comes from an active Apple Developer Program membership -- until
enrollment completes there is no APNs key, no distribution certificate, no
TestFlight and no App Store submission.

To build something runnable in the meantime:

  flutter build ios --simulator --debug"
  fi

  flutter build ipa --release || die "ipa build failed"
  ARTEFACT=$(find build/ios/ipa -name "*.ipa" 2>/dev/null | head -1)
  [ -n "$ARTEFACT" ] || die "no .ipa was produced"

  ok "  $ARTEFACT ($(du -h "$ARTEFACT" | cut -f1))"
  printf '\n  Upload with Transporter, or:\n'
  printf '    xcrun altool --upload-app -f "%s" -t ios --apiKey <id> --apiIssuer <issuer>\n' "$ARTEFACT"
fi

# ---------------------------------------------------------------------------
say "after this"
# ---------------------------------------------------------------------------

cat <<'NEXT'
  The artefact is built. Before it can be reviewed, in the store console:

    - privacy answers matching ios/Runner/PrivacyInfo.xcprivacy
    - age rating; a mental-health app with user content attracts the 17+ path
    - screenshots on every required device size
    - privacy policy URL: https://venttly.com/privacy
    - a demo account in App Review notes. Venttly is pseudonymous and a
      reviewer cannot sign up and find anything to look at; give them an
      account that already has vents, tribes and a friend.
    - tell them where in-app account deletion is. It exists, in Settings, and
      a reviewer who cannot find it rejects for its absence.
NEXT
