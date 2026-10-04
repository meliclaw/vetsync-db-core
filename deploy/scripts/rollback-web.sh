#!/usr/bin/env bash
# ==============================================================================
# rollback-web.sh — return frontend traffic to the previous colour.
#
# Works only while the previous colour is still running (24 h window by
# convention). Takes seconds; no rebuild, no image pull.
# ==============================================================================
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/opt/vetsync/current/compose.prod.yml}"
SNIPPET="${SNIPPET:-/srv/vetsync/caddy/snippets/web-upstream.caddy}"

if [ ! -f "${SNIPPET}.previous" ]; then
  echo "No ${SNIPPET}.previous — nothing to roll back to." >&2
  exit 1
fi

PREV=$(grep -oE 'web-(blue|green)' "${SNIPPET}.previous" | head -1 | cut -d- -f2)
CID=$(docker compose -f "$COMPOSE_FILE" ps -q "web-${PREV}" 2>/dev/null || true)
if [ -z "$CID" ]; then
  echo "web-${PREV} is no longer running; redeploy its digest with deploy-web.sh instead." >&2
  exit 1
fi

printf '\033[1m==>\033[0m rolling frontend back to %s\n' "$PREV"
cp "$SNIPPET" "${SNIPPET}.failed"
mv "${SNIPPET}.previous" "$SNIPPET"

docker compose -f "$COMPOSE_FILE" exec -T caddy \
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

printf '\033[1m==>\033[0m %s is serving again\n' "$PREV"
printf '    failed config kept at %s.failed\n' "$SNIPPET"
