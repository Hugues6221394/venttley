#!/usr/bin/env bash
set -euo pipefail

# Runtime integration coverage for the impact/admin trust boundary. The script
# creates one ephemeral local Auth account, exercises PostgREST with a real JWT,
# demotes the account to prove authorization is evaluated at request time, and
# removes the account on exit. It never prints credentials or tokens.

status_env="$(supabase status -o env 2>/dev/null)"
read_status_value() {
  printf '%s\n' "$status_env" | awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }'
}

api_url="$(read_status_value API_URL)"
rest_url="$(read_status_value REST_URL)"
db_url="$(read_status_value DB_URL)"
anon_key="$(read_status_value ANON_KEY)"
service_key="$(read_status_value SERVICE_ROLE_KEY)"

if [[ -z "$api_url" || -z "$rest_url" || -z "$db_url" || -z "$anon_key" || -z "$service_key" ]]; then
  echo "Local Supabase is unavailable or did not return the required status fields." >&2
  exit 1
fi

suffix="$(date +%s)-$$"
test_email="impact-integration-${suffix}@example.test"
test_password="Local-impact-${suffix}-Aa1!"
test_pseudonym="impact${suffix//-/}"
create_body="$(mktemp)"
login_body="$(mktemp)"
rpc_body="$(mktemp)"
test_user_id=""

cleanup() {
  if [[ "$test_user_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    curl --silent --show-error --request DELETE \
      --header "apikey: ${service_key}" \
      --header "Authorization: Bearer ${service_key}" \
      "${api_url}/auth/v1/admin/users/${test_user_id}" >/dev/null 2>&1 || true
    psql "$db_url" -X -v ON_ERROR_STOP=1 \
      -c "DELETE FROM public.users WHERE user_id='${test_user_id}'::uuid" >/dev/null 2>&1 || true
  fi
  rm -f "$create_body" "$login_body" "$rpc_body"
}
trap cleanup EXIT

create_status="$(curl --silent --show-error --output "$create_body" --write-out '%{http_code}' \
  --request POST \
  --header "apikey: ${service_key}" \
  --header "Authorization: Bearer ${service_key}" \
  --header 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$test_email" --arg password "$test_password" --arg pseudonym "$test_pseudonym" \
    '{email:$email,password:$password,email_confirm:true,user_metadata:{pseudonym:$pseudonym,avatar_seed:$pseudonym,birth_year:"1990",birth_month:"1"}}')" \
  "${api_url}/auth/v1/admin/users")"
if [[ "$create_status" != "200" && "$create_status" != "201" ]]; then
  echo "Failed to create the ephemeral local Auth account (HTTP ${create_status})." >&2
  exit 1
fi

test_user_id="$(jq -r '.id // empty' "$create_body")"
if [[ ! "$test_user_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "The local Auth response did not contain a valid user id." >&2
  exit 1
fi

username="$test_pseudonym"
psql "$db_url" -X -v ON_ERROR_STOP=1 \
  -c "INSERT INTO public.users (user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year) VALUES ('${test_user_id}'::uuid,'${username}','${username}','integration-only','Impact Integration','impact integration','${username}','super_admin','active',1990) ON CONFLICT (user_id) DO UPDATE SET user_role='super_admin',account_status='active'" \
  >/dev/null

login_status="$(curl --silent --show-error --output "$login_body" --write-out '%{http_code}' \
  --request POST \
  --header "apikey: ${anon_key}" \
  --header 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$test_email" --arg password "$test_password" \
    '{email:$email,password:$password}')" \
  "${api_url}/auth/v1/token?grant_type=password")"
if [[ "$login_status" != "200" ]]; then
  echo "Failed to obtain an authenticated local session (HTTP ${login_status})." >&2
  exit 1
fi
access_token="$(jq -r '.access_token // empty' "$login_body")"
if [[ -z "$access_token" ]]; then
  echo "The local login response did not contain an access token." >&2
  exit 1
fi

call_rpc() {
  local rpc_name="$1"
  local payload="$2"
  curl --silent --show-error --output "$rpc_body" --write-out '%{http_code}' \
    --request POST \
    --header "apikey: ${anon_key}" \
    --header "Authorization: Bearer ${access_token}" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "${rest_url}/rpc/${rpc_name}"
}

method_status="$(call_rpc admin_impact_methodology '{}')"
if [[ "$method_status" != "200" ]] || ! jq -e 'type == "array" and length >= 17' "$rpc_body" >/dev/null; then
  echo "An authenticated super admin could not read the impact methodology RPC." >&2
  exit 1
fi

snapshot_status="$(call_rpc admin_control_plane_snapshot '{"p_section":"experiments"}')"
if [[ "$snapshot_status" != "200" ]] || ! jq -e '.section == "experiments" and .privacy == "aggregate_only"' "$rpc_body" >/dev/null; then
  snapshot_detail="$(jq -r 'if type == "object" then (.message // .section // "unexpected object") else type end' "$rpc_body" 2>/dev/null || echo 'invalid response')"
  echo "An authenticated super admin could not read the aggregate control-plane RPC (HTTP ${snapshot_status}: ${snapshot_detail})." >&2
  exit 1
fi

support_queue_status="$(call_rpc admin_support_case_queue '{"p_limit":10}')"
if [[ "$support_queue_status" != "200" ]] || ! jq -e 'type == "array"' "$rpc_body" >/dev/null; then
  echo "An authenticated super admin could not read the canonical support-case RPC." >&2
  exit 1
fi

support_mutation_status="$(call_rpc admin_create_support_case '{"p_operation":"1a440000-0000-4000-8000-000000000001","p_source_kind":"other","p_source_id":null,"p_member":null,"p_category":"technical","p_priority":"normal"}')"
if [[ "$support_mutation_status" == "200" ]] || ! jq -e '.message | contains("aal2_required")' "$rpc_body" >/dev/null; then
  echo "Operational mutation did not fail closed for an AAL1 PostgREST session." >&2
  exit 1
fi

aal_status="$(call_rpc admin_generate_impact_report '{"p_report_kind":"monthly_impact","p_title":"AAL1 must fail","p_audience":"internal","p_window_start":"2026-08-01","p_window_end":"2026-08-31","p_country_source":"none","p_country_filter":null,"p_notes":"integration test"}')"
if [[ "$aal_status" == "200" ]] || ! jq -e '.message | contains("aal2_required")' "$rpc_body" >/dev/null; then
  echo "Report generation did not fail closed for an AAL1 session." >&2
  exit 1
fi

psql "$db_url" -X -v ON_ERROR_STOP=1 \
  -c "UPDATE public.users SET user_role='normal' WHERE user_id='${test_user_id}'::uuid" >/dev/null
member_status="$(call_rpc admin_impact_methodology '{}')"
if [[ "$member_status" == "200" ]] || ! jq -e '.message | contains("not_authorized")' "$rpc_body" >/dev/null; then
  echo "A demoted member retained impact-administration access." >&2
  exit 1
fi
member_support_status="$(call_rpc admin_support_case_queue '{"p_limit":10}')"
if [[ "$member_support_status" == "200" ]] || ! jq -e '.message | contains("not_authorized")' "$rpc_body" >/dev/null; then
  echo "A demoted member retained support-case access." >&2
  exit 1
fi

anonymous_status="$(curl --silent --show-error --output "$rpc_body" --write-out '%{http_code}' \
  --request POST --header "apikey: ${anon_key}" --header 'Content-Type: application/json' \
  --data '{}' "${rest_url}/rpc/admin_impact_methodology")"
if [[ "$anonymous_status" == "200" ]]; then
  echo "Anonymous PostgREST access to impact methodology was not denied." >&2
  exit 1
fi

anonymous_support_status="$(curl --silent --show-error --output "$rpc_body" --write-out '%{http_code}' \
  --request POST --header "apikey: ${anon_key}" --header 'Content-Type: application/json' \
  --data '{"p_limit":10}' "${rest_url}/rpc/admin_support_case_queue")"
if [[ "$anonymous_support_status" == "200" ]]; then
  echo "Anonymous PostgREST access to support cases was not denied." >&2
  exit 1
fi

echo "impact_admin_postgrest: impact and governance reads allowed; AAL1 mutation, member, and anonymous callers denied."
