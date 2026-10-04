#!/usr/bin/env bash
# ==============================================================================
# smoke-test.sh — post-deploy verification.
#
# Run after every deployment and after every restore. Exits non-zero on any
# failure, so deploy.sh can roll back automatically.
#
#   ./smoke-test.sh                 # against the public domains
#   TARGET=local ./smoke-test.sh    # against 127.0.0.1:8000 on the host
# ==============================================================================
set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/vetsync/prd.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

TARGET="${TARGET:-public}"
if [ "$TARGET" = "local" ]; then
  API="http://127.0.0.1:8000"
else
  API="https://${API_DOMAIN}"
fi
APP="https://${APP_DOMAIN}"

FAIL=0
pass() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

# ---------------------------------------------------------------- containers
head_ "Containers"
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null)
[ -z "$UNHEALTHY" ] && pass "no unhealthy containers" || fail "unhealthy: $UNHEALTHY"

RESTARTING=$(docker ps --filter "status=restarting" --format '{{.Names}}' 2>/dev/null)
[ -z "$RESTARTING" ] && pass "no restart loops" || fail "restarting: $RESTARTING"

# ---------------------------------------------------------------- database
head_ "Database"
if docker compose exec -T db pg_isready -U postgres >/dev/null 2>&1; then
  pass "postgres accepting connections"
else
  fail "postgres not ready"
fi

# The multi-tenant boundary IS the security model. A table in `public`
# without RLS leaks every organization's clinical data at once.
NORLS=$(docker compose exec -T db psql -U postgres -tAc "
  select count(*) from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;" 2>/dev/null | tr -dc '0-9')
if [ "${NORLS:-1}" = "0" ]; then
  pass "every public table has RLS enabled"
else
  fail "${NORLS} public table(s) WITHOUT RLS — cross-tenant exposure"
  docker compose exec -T db psql -U postgres -tAc "
    select '        ' || c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname='public' and c.relkind='r' and not c.relrowsecurity limit 20;" 2>/dev/null
fi

TABLES=$(docker compose exec -T db psql -U postgres -tAc \
  "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null | tr -dc '0-9')
[ "${TABLES:-0}" -gt 100 ] && pass "${TABLES} tables in public" \
  || fail "only ${TABLES:-0} tables in public — expected ~158"

# ------------------------------------------------------------------- gateway
head_ "API gateway"
# /rest/v1/ (exact root) serves the OpenAPI schema and is admin-only by ACL
# (kong.yml rest-v1-openapi route) — anon must get 403, not the schema doc.
C=$(code -H "apikey: ${ANON_KEY}" "${API}/rest/v1/")
[ "$C" = "403" ] && pass "PostgREST /rest/v1/ (openapi, anon) -> $C" \
  || fail "PostgREST /rest/v1/ (openapi, anon) -> $C, expected 403"

C=$(code "${API}/rest/v1/")
[ "$C" = "401" ] && pass "PostgREST /rest/v1/ (no apikey) -> $C" \
  || fail "PostgREST /rest/v1/ (no apikey) -> $C, expected 401"

# /auth/v1/health is not in Kong's auth-v1-open route list, so it requires apikey.
C=$(code -H "apikey: ${ANON_KEY}" "${API}/auth/v1/health")
[ "$C" = "200" ] && pass "GoTrue /auth/v1/health -> $C" || fail "GoTrue /auth/v1/health -> $C"

C=$(code -H "apikey: ${ANON_KEY}" "${API}/storage/v1/bucket")
[ "$C" = "200" ] || [ "$C" = "400" ] && pass "Storage reachable -> $C" || fail "Storage -> $C"

C=$(code "${API}/functions/v1/")
[ "$C" != "000" ] && pass "Edge runtime reachable -> $C" || fail "Edge runtime unreachable"

# Anonymous requests must be rejected, not served.
C=$(code "${API}/rest/v1/organizations")
[ "$C" = "401" ] && pass "unauthenticated REST rejected -> 401" \
  || fail "unauthenticated REST returned $C, expected 401"

# ------------------------------------------------------- dashboard isolation
head_ "Studio isolation"
if [ "$TARGET" != "local" ]; then
  C=$(code "${API}/")
  [ "$C" = "404" ] && pass "dashboard blocked on api host -> 404" \
    || fail "api host returned $C for '/' — Studio may be publicly reachable"

  C=$(code "${API}/pg/")
  [ "$C" = "404" ] && pass "pg-meta blocked on api host -> 404" \
    || fail "api host returned $C for '/pg/' — schema API exposed"

  for h in console.vetsync.com.br studio.vetsync.com.br; do
    R=$(getent hosts "$h" | awk '{print $1}' | head -1)
    case "$R" in
      "")        pass "$h does not resolve publicly" ;;
      100.*)     pass "$h resolves to tailnet space ($R)" ;;
      *)         fail "$h resolves to $R — Studio must not be public" ;;
    esac
  done
fi

# ----------------------------------------------------------------- frontend
head_ "Web application"
if [ "$TARGET" != "local" ]; then
  C=$(code "${APP}/")
  [ "$C" = "200" ] && pass "app shell -> 200" || fail "app shell -> $C"

  C=$(code "${APP}/config.json")
  [ "$C" = "200" ] && pass "runtime config served -> 200" || fail "/config.json -> $C"

  if curl -s --max-time 10 "${APP}/config.json" | jq -e '.SUPABASE_URL | startswith("https://")' >/dev/null 2>&1; then
    pass "runtime config points at an https API"
  else
    fail "runtime config SUPABASE_URL is not an https URL"
  fi

  H=$(curl -sI --max-time 10 "${APP}/" | tr -d '\r')
  grep -qi '^strict-transport-security:' <<<"$H" && pass "HSTS present" || fail "HSTS missing"
  grep -qi '^x-frame-options:' <<<"$H" && pass "X-Frame-Options present" || fail "X-Frame-Options missing"
fi

# ------------------------------------------------------------------- verdict
head_ "Result"
printf '  %d failure(s)\n\n' "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
