#!/bin/sh
# Custom entrypoint for Kong that builds Lua expressions for request-transformer
# and performs environment variable substitution in the declarative config.

# Build Lua expressions for translating opaque API keys (sb_publishable_ / sb_secret_)
# into JWTs that upstream services (Auth/Realtime/PostgREST) can validate.
#
# When opaque keys are not configured (empty env vars), expressions fall through
# to legacy-only behavior - just passing apikey as-is.
#
# Full expression logic (when opaque keys are configured):
#   1. If Authorization header exists and is NOT an sb_ key -> pass through (user session JWT)
#   2. If apikey matches secret key -> set service_role JWT
#   3. If apikey matches publishable key -> set anon JWT
#   4. Fallback: pass apikey as-is (legacy HS256 JWT)
#
# Prefer asymmetric internal JWTs when present; otherwise fall back to legacy
# HS256 ANON/SERVICE keys. Empty asymmetric values must NOT be used in Lua
# `and` chains — empty string is truthy in Lua and would swallow the fallback.

ANON_INTERNAL_JWT="${ANON_KEY_ASYMMETRIC:-}"
SERVICE_INTERNAL_JWT="${SERVICE_ROLE_KEY_ASYMMETRIC:-}"
if [ -z "$ANON_INTERNAL_JWT" ]; then
  ANON_INTERNAL_JWT="${SUPABASE_ANON_KEY:-}"
fi
if [ -z "$SERVICE_INTERNAL_JWT" ]; then
  SERVICE_INTERNAL_JWT="${SUPABASE_SERVICE_KEY:-}"
fi

if [ -n "$SUPABASE_SECRET_KEY" ] && [ -n "$SUPABASE_PUBLISHABLE_KEY" ] && [ -n "$ANON_INTERNAL_JWT" ]; then
    # Opaque keys configured -> translate to internal JWTs (asymmetric or HS256)
    export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or (headers.apikey == '$SUPABASE_SECRET_KEY' and 'Bearer $SERVICE_INTERNAL_JWT') or (headers.apikey == '$SUPABASE_PUBLISHABLE_KEY' and 'Bearer $ANON_INTERNAL_JWT') or headers.apikey)"

    # Realtime WebSocket: reads from query_params.apikey (supabase-js sends apikey
    # via query string), outputs to x-api-key header which Realtime checks first.
    export LUA_RT_WS_EXPR="\$((query_params.apikey == '$SUPABASE_SECRET_KEY' and '$SERVICE_INTERNAL_JWT') or (query_params.apikey == '$SUPABASE_PUBLISHABLE_KEY' and '$ANON_INTERNAL_JWT') or query_params.apikey)"
else
    # Legacy API keys, not sb_ API keys -> pass apikey through unchanged
    export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or headers.apikey)"
    export LUA_RT_WS_EXPR="\$(query_params.apikey)"
fi

# Substitute environment variables in the Kong declarative config.
# Uses awk instead of eval/echo to preserve YAML quoting (eval strips double
# quotes, breaking "Header: value" patterns that YAML parses as mappings).
awk '{
  result = ""
  rest = $0
  while (match(rest, /\$[A-Za-z_][A-Za-z_0-9]*/)) {
    varname = substr(rest, RSTART + 1, RLENGTH - 1)
    if (varname in ENVIRON) {
      result = result substr(rest, 1, RSTART - 1) ENVIRON[varname]
    } else {
      result = result substr(rest, 1, RSTART + RLENGTH - 1)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  print result rest
}' /home/kong/temp.yml > "$KONG_DECLARATIVE_CONFIG"

# Remove empty key-auth credentials (unconfigured opaque keys)
sed -i '/^[[:space:]]*- key:[[:space:]]*$/d' "$KONG_DECLARATIVE_CONFIG"

exec /entrypoint.sh kong docker-start
