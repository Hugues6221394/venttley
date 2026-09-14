#!/usr/bin/env bash
#
# Deploy the console.
#
#   ./scripts/deploy.sh staging
#   ./scripts/deploy.sh production
#
# WHY NOT JUST `vercel --prod`
#
# Two Vercel projects now share this code and differ only in which database
# they point at. `vercel --prod` deploys to whichever project the directory
# happens to be linked to, and `--project` is a flag that can be forgotten
# exactly once — after which staging's build is serving the live moderation
# console, or a half-written page is live over real member data.
#
# So the environment is an argument, not a default, and the two hazards that
# make a wrong deploy possible are checked before anything is uploaded:
#
#   * Uncommitted changes. `vercel` uploads the working directory, not a
#     commit. A second session builds pages in the main tree while this one
#     deploys; a deploy fired from a dirty tree ships whatever was on disk at
#     that instant. See PARALLEL-WORK.md.
#   * Deploying to production without saying so out loud.

set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  staging)    PROJECT="venttly-admin-staging"; SUPABASE_REF="rbtvilckwihzdpqgjvmz" ;;
  production) PROJECT="venttly-admin-prod";    SUPABASE_REF="gyeibgaqrmnepbnfbtzc" ;;
  *) die "Usage: $0 staging|production" ;;
esac

# --- the tree must be committed ---------------------------------------------

if [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  git status --short -- . | head -10
  die "
admin/ has uncommitted changes and vercel uploads the directory, not a commit.
Deploy from the worktree at ../Venttly-deploy, which only ever holds committed
work — see PARALLEL-WORK.md. Commit here, then merge and deploy there."
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
SHA=$(git rev-parse --short HEAD)

say "target"
echo "  environment : $ENV_NAME"
echo "  vercel      : $PROJECT"
echo "  supabase    : $SUPABASE_REF"
echo "  commit      : $SHA on $BRANCH"

# --- production is typed out in full ----------------------------------------

if [ "$ENV_NAME" = "production" ]; then
  printf '\n\033[31mThis is the live console: real members, real suspensions, real audit log.\033[0m\n'
  printf 'Type the word production to continue: '
  read -r confirm
  [ "$confirm" = "production" ] || die "Stopped."
fi

# --- checks before upload, not after ----------------------------------------

say "typecheck"
npm run --silent typecheck || die "typecheck failed — not deploying."

say "build"
npm run --silent build >/dev/null || die "build failed — not deploying."
ok "  built"

say "deploying to $PROJECT"
npx vercel deploy --prod --yes --project "$PROJECT"

say "after this"
echo "  Open /settings → Environment and read the badge in the top right."
echo "  It must say $ENV_NAME. If it does not, NEXT_PUBLIC_ADMIN_ENV is wrong"
echo "  on $PROJECT and the console is lying about which system you are on."
