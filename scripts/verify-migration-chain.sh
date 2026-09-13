#!/usr/bin/env bash
#
# Replay the whole migration chain into a throwaway database and run the
# contract suite against it. Use this before `supabase db push` to production.
#
#   ./scripts/verify-migration-chain.sh
#
# WHY THIS SCRIPT EXISTS, AND WHY IT ASSERTS ITS OWN ENVIRONMENT
#
# The first version of this check was run by hand against a bare
# supabase/postgres container. It reported "240 of 240 applied, zero failures"
# and that was taken as proof the chain would apply to a real project. It was
# not. A bare container ships with NO pre-installed extensions, so
# `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"` genuinely created one in
# `public` and the unqualified `uuid_generate_v4()` in 0001 resolved. On a real
# Supabase project that extension is pre-installed in the `extensions` schema,
# the CREATE is a no-op, and 0001 fails on the first table it tries to make.
#
# That difference took production down. The probe was missing precisely the
# condition being verified, and it reported confidence instead of a gap.
#
# So this script does not just replay the chain. It first asserts that the
# probe RESEMBLES a real Supabase project in the ways that have already bitten
# us, and refuses to report success if it does not. A verification environment
# that differs from the target in the dimension under test is not a weaker
# test — it is a false one.
#
# Prerequisites the chain needs that are not in the SQL:
#   1. pg_cron available (cluster-wide; only in the `postgres` database)
#   2. vault secret `account_purge_cron_secret` present before 20260915090000
#   3. `extensions` on the connection search_path (the one that bit us)

set -uo pipefail

NAME=venttly_chain_probe
PORT=${PROBE_PORT:-54399}
IMAGE=$(docker inspect supabase_db_Venttly --format '{{.Config.Image}}' 2>/dev/null \
        || echo "public.ecr.aws/supabase/postgres:17.6.1.121")
LOCAL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
PROBE="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
ADMIN=(env PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PORT" -U supabase_admin -d postgres)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
die() { printf '\033[31mFAIL: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Nothing uncommitted may be deployed
#
# A migration that is applied to production but untracked in git is drift with
# a delay on it: edit the file afterwards and production silently stops
# matching the repository, with nothing able to detect the divergence. That is
# how production ended up with a schema running ahead of its own ledger, and
# nobody could say by how much.
#
# This runs first, before the container even starts, because it is the cheapest
# check here and the most expensive one to skip.
# ---------------------------------------------------------------------------

say "checking every migration is committed"
DIRTY=$(git status --porcelain -- supabase/migrations 2>/dev/null)
if [ -n "$DIRTY" ]; then
  printf '%s\n' "$DIRTY" | sed 's/^/  /'
  die "migration files are untracked or modified — commit them before deploying what they describe"
fi
printf '  ok    all %s migration files are tracked and clean\n' \
  "$(ls supabase/migrations/*.sql | wc -l | tr -d ' ')"

say "starting a clean probe on :$PORT ($IMAGE)"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -p "${PORT}:5432" "$IMAGE" >/dev/null \
  || die "could not start the probe container"
for _ in $(seq 1 30); do
  docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 5
done
sleep 5
docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 || die "probe never became ready"

# ---------------------------------------------------------------------------
# Make the probe resemble a real project
# ---------------------------------------------------------------------------

say "bootstrapping the Supabase-provided surface"

# storage.* is created by the storage-api service at run time, not by the
# image, and not by our chain. Copy its shape from the local stack, then grant
# what the real service grants — without this, tribe/media migrations fail on
# permissions that have nothing to do with our SQL.
docker exec supabase_db_Venttly pg_dump -U postgres -d postgres \
  --schema-only --no-owner --no-privileges --schema=storage > "$WORK/storage.sql" 2>/dev/null \
  || die "could not dump storage schema from the local stack (is it running?)"
"${ADMIN[@]}" -q -v ON_ERROR_STOP=0 -f "$WORK/storage.sql" >/dev/null 2>&1
# The service grants full DML to the API roles, not just to postgres. Granting
# only postgres made 0030_tribe_media_storage fail on a privilege the real
# platform provides — a probe artifact masquerading as a chain defect.
"${ADMIN[@]}" -q -c "
  GRANT ALL ON SCHEMA storage TO postgres, anon, authenticated, service_role;
  GRANT ALL ON ALL TABLES IN SCHEMA storage TO postgres, anon, authenticated, service_role;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO postgres, anon, authenticated, service_role;
  GRANT ALL ON ALL FUNCTIONS IN SCHEMA storage TO postgres, anon, authenticated, service_role;" >/dev/null 2>&1

# The image's `auth` schema is older than the platform's — GoTrue migrates it
# in a real project. Ours lacked auth.users.email_confirmed_at, which aborted
# 0026 before a single assertion ran. Take the current shape from the local
# stack instead of trusting the image.
docker exec supabase_db_Venttly pg_dump -U postgres -d postgres \
  --schema-only --no-owner --no-privileges --schema=auth > "$WORK/auth.sql" 2>/dev/null \
  || die "could not dump auth schema from the local stack"
"${ADMIN[@]}" -q -c "DROP SCHEMA auth CASCADE; CREATE SCHEMA auth;" >/dev/null 2>&1
"${ADMIN[@]}" -q -v ON_ERROR_STOP=0 -f "$WORK/auth.sql" >/dev/null 2>&1
"${ADMIN[@]}" -q -c "
  GRANT USAGE ON SCHEMA auth TO postgres, anon, authenticated, service_role;
  GRANT ALL ON ALL TABLES IN SCHEMA auth TO postgres, service_role;
  GRANT SELECT ON auth.users TO postgres, authenticated, service_role;" >/dev/null 2>&1

# Real projects keep uuid-ossp and pgcrypto in `extensions`, pre-installed.
# Reproduce that, because it is the exact shape that broke production.
"${ADMIN[@]}" -q -c "
  CREATE SCHEMA IF NOT EXISTS extensions;
  CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\" WITH SCHEMA extensions;
  CREATE EXTENSION IF NOT EXISTS pgcrypto     WITH SCHEMA extensions;" >/dev/null 2>&1

# Prerequisite 3: the chain calls uuid_generate_v4() unqualified.
psql "$PROBE" -q -c 'ALTER DATABASE postgres SET search_path TO "$user", public, extensions;' >/dev/null 2>&1

# Prerequisite 2: 20260915090000 refuses without this, deliberately.
psql "$PROBE" -q -c "SELECT vault.create_secret('probe-only-not-a-real-secret','account_purge_cron_secret','chain probe');" >/dev/null 2>&1

# The platform's auth.uid() also reads the request.jwt.claims JSON blob; the
# image ships an older one that only reads request.jwt.claim.sub. Tests set the
# JSON form, so without this the suite silently fails on anything actor-aware.
"${ADMIN[@]}" -q -c "
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS \$\$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid \$\$;" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Refuse to proceed unless the probe is actually faithful
# ---------------------------------------------------------------------------

say "asserting the probe resembles a real project"
check() {
  local label=$1 sql=$2
  local got; got=$(psql "$PROBE" -tAc "$sql" 2>/dev/null | tr -d '[:space:]')
  if [ "$got" = "t" ]; then printf '  ok    %s\n' "$label"
  else printf '  \033[31mBAD   %s\033[0m\n' "$label"; FAITHFUL=0; fi
}
FAITHFUL=1
check "uuid-ossp pre-installed in extensions (not public)" \
  "select n.nspname='extensions' from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='uuid-ossp'"
check "pgcrypto in extensions" \
  "select n.nspname='extensions' from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto'"
check "pg_cron installable here" \
  "select true from pg_settings where name='cron.database_name' and setting=current_database()"
check "storage.objects present" "select to_regclass('storage.objects') is not null"
check "auth.users present"      "select to_regclass('auth.users') is not null"
check "auth schema is the platform's, not the image's" \
  "select exists(select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='email_confirmed_at')"
check "storage granted to the API roles" \
  "select has_table_privilege('authenticated','storage.objects','INSERT')"
check "vault secret seeded"     "select exists(select 1 from vault.decrypted_secrets where name='account_purge_cron_secret')"
check "auth.uid() reads request.jwt.claims" \
  "select set_config('request.jwt.claims','{\"sub\":\"11111111-1111-4111-8111-111111111111\"}',false) is not null and auth.uid() is not null"
[ "$FAITHFUL" = "1" ] || die "the probe does not resemble a real project; results would be meaningless"

# ---------------------------------------------------------------------------
# Replay
# ---------------------------------------------------------------------------

say "replaying the migration chain"
pass=0; fail=0; first=""
for f in $(ls supabase/migrations/*.sql | sort); do
  if psql "$PROBE" -q -v ON_ERROR_STOP=1 -f "$f" > "$WORK/one.log" 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); [ -z "$first" ] && first=$(basename "$f")
    printf '  \033[31m%s\033[0m\n' "$(basename "$f")"
    grep -m1 ERROR "$WORK/one.log" | sed 's/^/      /'
  fi
done
printf '\n  applied %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || die "chain does not apply cleanly (first failure: $first)"

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------

say "running the contract suite against the rebuilt database"
psql "$PROBE" -tAc "CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions" >/dev/null 2>&1
tot=0; bad=0; zero=""
for f in supabase/tests/database/*.test.sql; do
  out=$(psql "$PROBE" -q -f "$f" 2>&1)
  n=$(echo "$out" | grep -cE "^ (not )?ok [0-9]+"); k=$(echo "$out" | grep -c "^ not ok")
  tot=$((tot+n)); bad=$((bad+k))
  [ "$n" -eq 0 ] && zero="$zero $(basename "$f" .test.sql)"
  [ "$k" -gt 0 ] && printf '  \033[31mFAIL %-44s %s of %s\033[0m\n' "$(basename "$f" .test.sql)" "$k" "$n"
done
printf '\n  %s assertions, %s failed\n' "$tot" "$bad"
# A file that runs zero assertions reports no failures while testing nothing —
# 0020 did exactly that for months. Treat it as a failure, not a curiosity.
[ -z "$zero" ] || die "these files ran ZERO assertions:$zero"
[ "$bad" -eq 0 ] || die "contract failures on a database built only from the chain"

say "chain verified — $pass migrations, $tot assertions"
echo "  probe left running on :$PORT for inspection; remove with: docker rm -f $NAME"
