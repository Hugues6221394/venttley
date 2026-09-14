#!/usr/bin/env bash
#
# Configure a Vercel project for the console.
#
#   ./scripts/setup-vercel.sh staging
#   ./scripts/setup-vercel.sh production
#
# Run from admin/, after `npx vercel login` and `npx vercel link`.
#
# WHY A SCRIPT
#
# Eleven environment variables, two of them credentials that must never be
# pasted into a chat window or committed, and one — the Supabase service role
# key — that bypasses RLS on every table in the database it belongs to. Setting
# those by hand eleven times across two projects is how the wrong key ends up
# in the wrong environment, and the failure is silent: the console works
# perfectly while pointed at the wrong database.
#
# So the Supabase keys are fetched from the management API at run time, keyed
# on the project ref for the environment you named. They are never stored here,
# never printed, and cannot be crossed over by a copy-paste slip.
#
# Everything is set at Vercel's *production* scope even for the staging
# project, because a Vercel project has its own production environment; the
# staging-ness is which Supabase database it points at, not which scope the
# variables sit in.

set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  staging)    SUPABASE_REF="rbtvilckwihzdpqgjvmz" ;;
  production) SUPABASE_REF="gyeibgaqrmnepbnfbtzc" ;;
  *) die "Usage: $0 staging|production" ;;
esac

# --- preconditions, all of them, before changing anything -------------------

command -v npx >/dev/null || die "npx not found"

npx vercel whoami >/dev/null 2>&1 || die \
  "Not logged in to Vercel. Run:  npx vercel login  (then: npx vercel link)"

[ -d .vercel ] || die \
  "No .vercel directory — this repo is not linked to a Vercel project yet.
   Run:  npx vercel link
   Create a SEPARATE project per environment; one project cannot hold two
   databases."

TOKEN_FILE="$HOME/.supabase/access-token"
[ -f "$TOKEN_FILE" ] || die "No Supabase access token at $TOKEN_FILE. Run: supabase login"

LINKED=$(python3 -c "import json;print(json.load(open('.vercel/project.json'))['projectId'])" 2>/dev/null || echo "?")
say "target"
echo "  environment      : $ENV_NAME"
echo "  supabase project : $SUPABASE_REF"
echo "  vercel project   : $LINKED"
echo
printf "Is that the right Vercel project for %s? [y/N] " "$ENV_NAME"
read -r reply
[ "$reply" = "y" ] || die "Stopped. Run 'npx vercel link' to point at the right project."

# --- secrets that only you can supply ---------------------------------------

say "Upstash"
echo "Each environment needs its OWN Redis database. Sharing one means staging"
echo "logins spend production's rate-limit budget for the same key — and the"
echo "limiter fails closed, so the failure mode is people locked out of the"
echo "real console by test traffic."
echo
read -r -p "  UPSTASH_REDIS_REST_URL   : " UPSTASH_URL
read -r -s -p "  UPSTASH_REDIS_REST_TOKEN : " UPSTASH_TOKEN; echo
[ -n "$UPSTASH_URL" ] && [ -n "$UPSTASH_TOKEN" ] || die "Both Upstash values are required — without them login refuses in production."

# --- Supabase keys, fetched rather than typed -------------------------------

say "fetching Supabase keys for $SUPABASE_REF"
KEYS=$(curl -sS "https://api.supabase.com/v1/projects/$SUPABASE_REF/api-keys" \
        -H "Authorization: Bearer $(cat "$TOKEN_FILE")")

ANON=$(printf '%s' "$KEYS" | python3 -c "
import json,sys
for k in json.load(sys.stdin):
    if k.get('name') == 'anon': print(k['api_key']); break")
SERVICE=$(printf '%s' "$KEYS" | python3 -c "
import json,sys
for k in json.load(sys.stdin):
    if k.get('name') == 'service_role': print(k['api_key']); break")

[ -n "$ANON" ] && [ -n "$SERVICE" ] || die "Could not read the API keys for $SUPABASE_REF."
ok "  got anon + service_role (not printed)"

SUPABASE_URL="https://${SUPABASE_REF}.supabase.co"

# --- set them ----------------------------------------------------------------

# --value/--force/--non-interactive, not a pipe into stdin.
#
# Piping the value used to work and silently stopped: the CLI now inspects
# NEXT_PUBLIC_* values, decides the anon key "looks like a credential", and
# asks how to store it. A piped value answers the wrong question — the first
# run set NEXT_PUBLIC_SUPABASE_URL to the CLI's own prompt payload and dropped
# NEXT_PUBLIC_SUPABASE_ANON_KEY entirely, while printing "set" for both.
#
# Sensitivity is explicit rather than left to that heuristic. NEXT_PUBLIC_*
# values are inlined into client JavaScript at build time — they are public by
# definition and must stay readable, so Config. Everything else is a Secret.
set_var() { # name, value
  local sensitivity="--sensitive"
  case "$1" in NEXT_PUBLIC_*) sensitivity="--no-sensitive" ;; esac
  npx vercel env add "$1" production \
    --value "$2" --force --non-interactive $sensitivity >/dev/null 2>&1 \
    || die "Failed to set $1"
  echo "  set $1"
}

# Every variable is read back afterwards, because "set" printed by a script is
# not evidence that anything was stored.
verify_vars() {
  local listed missing=""
  listed=$(npx vercel env ls production 2>/dev/null)
  for name in NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY \
              SUPABASE_SERVICE_ROLE_KEY UPSTASH_REDIS_REST_URL \
              UPSTASH_REDIS_REST_TOKEN ADMIN_REQUIRE_MFA; do
    printf '%s' "$listed" | grep -q "^ $name " || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    die "These did not reach Vercel:$missing
   The console will fail at runtime in ways that look like Supabase outages."
  fi
  ok "  all six read back from Vercel"
}

say "setting environment variables (production scope)"
set_var NEXT_PUBLIC_SUPABASE_URL      "$SUPABASE_URL"
set_var NEXT_PUBLIC_SUPABASE_ANON_KEY "$ANON"
set_var SUPABASE_SERVICE_ROLE_KEY     "$SERVICE"
set_var UPSTASH_REDIS_REST_URL        "$UPSTASH_URL"
set_var UPSTASH_REDIS_REST_TOKEN      "$UPSTASH_TOKEN"
set_var ADMIN_REQUIRE_MFA             "true"

say "verifying"
verify_vars

# ADMIN_ORIGIN_SECRET is deliberately not set here. It has to match a
# Cloudflare Transform Rule that does not exist yet, and setting it first
# turns every request into a 404 — including the one you would use to check
# whether the deploy worked. DEPLOY.md step 6.
say "not set, on purpose"
echo "  ADMIN_ORIGIN_SECRET  — set it in step 6 of DEPLOY.md, after Cloudflare"
echo "                         has the matching Transform Rule."
echo "  ADMIN_IP_ALLOWLIST   — step 8, and only after the origin lock works."

say "next"
echo "  npx vercel --prod          deploy"
echo "  then /system → Environment and confirm every row is green"
ok "done"
