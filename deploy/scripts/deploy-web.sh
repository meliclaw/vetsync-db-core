#!/usr/bin/env bash
# ==============================================================================
# deploy-web.sh — blue/green release of the React application.
#
# The frontend is the ONLY component where blue/green is real: no schema, no
# shared volume, no migrations. Everything else uses controlled recreate.
#
#   ./deploy-web.sh rg.nl-ams.scw.cloud/vetsync/vetsync-web@sha256:<digest>
#
# Flow: start the idle colour -> health check -> smoke test it directly ->
# flip the Caddy snippet -> reload -> keep the old colour alive for rollback.
# ==============================================================================
set -euo pipefail

IMAGE="${1:?usage: deploy-web.sh <image@sha256:digest>}"

case "$IMAGE" in
  *@sha256:*) ;;
  *) echo "Refusing to deploy a floating tag. Pass image@sha256:<digest>." >&2; exit 2 ;;
esac

ENV_FILE="${ENV_FILE:-/etc/vetsync/prd.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/vetsync/current/compose.prod.yml}"
SNIPPET="${SNIPPET:-/srv/vetsync/caddy/snippets/web-upstream.caddy}"

set -a; . "$ENV_FILE"; set +a

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# --------------------------------------------------- which colour is serving
ACTIVE=$(grep -oE 'web-(blue|green)' "$SNIPPET" | head -1 | cut -d- -f2)
[ -n "$ACTIVE" ] || { echo "Cannot determine active colour from $SNIPPET" >&2; exit 1; }
if [ "$ACTIVE" = "blue" ]; then TARGET=green; else TARGET=blue; fi

log "active=$ACTIVE  candidate=$TARGET"
log "image=$IMAGE"

# ------------------------------------------------------ start the candidate
UPPER=$(echo "$TARGET" | tr '[:lower:]' '[:upper:]')
export "WEB_IMAGE_${UPPER}=$IMAGE"

log "pulling candidate image"
docker compose -f "$COMPOSE_FILE" --profile "$TARGET" pull "web-${TARGET}"

log "starting web-${TARGET}"
docker compose -f "$COMPOSE_FILE" --profile "$TARGET" up -d "web-${TARGET}"

# ------------------------------------------------------------ health gate
log "waiting for health"
for i in $(seq 1 30); do
  STATE=$(docker inspect -f '{{.State.Health.Status}}' \
    "$(docker compose -f "$COMPOSE_FILE" ps -q "web-${TARGET}")" 2>/dev/null || echo starting)
  [ "$STATE" = "healthy" ] && break
  [ "$i" -eq 30 ] && {
    echo "web-${TARGET} never became healthy; leaving $ACTIVE serving." >&2
    docker compose -f "$COMPOSE_FILE" logs --tail 50 "web-${TARGET}" >&2
    docker compose -f "$COMPOSE_FILE" --profile "$TARGET" rm -sf "web-${TARGET}"
    exit 1
  }
  sleep 2
done
log "web-${TARGET} healthy"

# --------------------------- verify the candidate BEFORE any traffic moves
log "probing candidate directly"
if ! docker compose -f "$COMPOSE_FILE" exec -T caddy \
     wget -q -O /dev/null "http://web-${TARGET}:8080/healthz"; then
  echo "candidate failed direct probe; aborting without switching." >&2
  docker compose -f "$COMPOSE_FILE" --profile "$TARGET" rm -sf "web-${TARGET}"
  exit 1
fi

# ------------------------------------------------------------- atomic flip
cp "$SNIPPET" "${SNIPPET}.previous"
cat > "$SNIPPET" <<EOF
# Managed by deploy-web.sh — DO NOT EDIT BY HAND.
# Switched $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${ACTIVE} to ${TARGET}
# Image: ${IMAGE}
#
# Current active colour: ${TARGET}

(web_upstream) {
	reverse_proxy web-${TARGET}:8080 {
		health_uri /healthz
		health_interval 5s
		health_timeout 2s
		lb_policy first
		fail_duration 10s
	}
}
EOF

log "reloading Caddy"
if ! docker compose -f "$COMPOSE_FILE" exec -T caddy \
     caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
  echo "Caddy reload failed; restoring previous upstream." >&2
  mv "${SNIPPET}.previous" "$SNIPPET"
  docker compose -f "$COMPOSE_FILE" exec -T caddy \
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  exit 1
fi

# --------------------------------------------------------- verify publicly
log "smoke testing through the public endpoint"
if ! /opt/vetsync/current/scripts/smoke-test.sh; then
  echo "smoke test failed; rolling back to ${ACTIVE}." >&2
  mv "${SNIPPET}.previous" "$SNIPPET"
  docker compose -f "$COMPOSE_FILE" exec -T caddy \
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
  exit 1
fi

# Record for rollback-web.sh, and persist the new digest.
echo "$ACTIVE" > /srv/vetsync/caddy/.previous-colour
sed -i "s|^WEB_IMAGE_${UPPER}=.*|WEB_IMAGE_${UPPER}=${IMAGE}|" "$ENV_FILE"

log "done: ${TARGET} is live"
log "previous colour ${ACTIVE} stays running for rollback — stop it after 24h:"
log "  docker compose -f $COMPOSE_FILE --profile $ACTIVE rm -sf web-$ACTIVE"
