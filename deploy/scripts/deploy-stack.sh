#!/usr/bin/env bash
# ==============================================================================
# deploy-stack.sh — controlled recreate of the Supabase services.
#
# NOT blue/green. One database, one Kong ingress, one storage tree: two
# concurrent versions would race on schema migrations (GoTrue and Storage
# both migrate at startup) and on storage.objects. This performs a guarded
# recreate with a verified backup and a manifest kept for rollback.
#
#   ./deploy-stack.sh                    # recreate changed services
#   ./deploy-stack.sh auth rest storage  # recreate only these
# ==============================================================================
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/vetsync/prd.env}"
RELEASE_DIR="${RELEASE_DIR:-/opt/vetsync/current}"
COMPOSE_FILE="${COMPOSE_FILE:-$RELEASE_DIR/compose.prod.yml}"
MANIFEST_DIR="/srv/vetsync/manifests"

set -a; . "$ENV_FILE"; set +a
mkdir -p "$MANIFEST_DIR"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

SERVICES=("$@")

# ------------------------------------------------- 1. validate the manifest
log "validating compose configuration"
docker compose -f "$COMPOSE_FILE" config -q || die "compose config is invalid"

# Floating tags make rollback impossible: `pull` would fetch something else.
if docker compose -f "$COMPOSE_FILE" config | grep -E '^\s+image:' | grep -qv '@sha256:'; then
  log "images without a digest:"
  docker compose -f "$COMPOSE_FILE" config | grep -E '^\s+image:' | grep -v '@sha256:' >&2
  die "every image must be pinned by digest"
fi

# ------------------------------------------------- 2. back up before schema
# GoTrue and Storage run migrations on startup. Never recreate them without
# a restorable backup taken first.
log "taking a pre-deploy backup"
"$RELEASE_DIR/scripts/backup.sh" --tag "pre-deploy-$(date -u +%Y%m%dT%H%M%SZ)" \
  || die "backup failed; refusing to deploy"

# ------------------------------------- 3. keep the running manifest for undo
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
docker compose -f "$COMPOSE_FILE" config > "$MANIFEST_DIR/manifest-$STAMP.yml"
ln -sfn "$MANIFEST_DIR/manifest-$STAMP.yml" "$MANIFEST_DIR/previous.yml"
log "manifest saved: $MANIFEST_DIR/manifest-$STAMP.yml"

# ----------------------------------------------------------- 4. pull images
log "pulling images by digest"
docker compose -f "$COMPOSE_FILE" pull "${SERVICES[@]}"

# -------------------------------------------------------------- 5. recreate
if [ ${#SERVICES[@]} -eq 0 ]; then
  log "recreating changed services"
  docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
else
  log "recreating: ${SERVICES[*]}"
  docker compose -f "$COMPOSE_FILE" up -d --no-deps "${SERVICES[@]}"
fi

# ------------------------------------------------------------ 6. health gate
log "waiting for health"
for i in $(seq 1 60); do
  BAD=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
        | jq -r 'select(.Health == "unhealthy" or .State == "restarting") | .Service' | sort -u)
  [ -z "$BAD" ] && break
  [ "$i" -eq 60 ] && {
    printf '\033[31munhealthy after 120s:\033[0m %s\n' "$BAD" >&2
    for s in $BAD; do docker compose -f "$COMPOSE_FILE" logs --tail 40 "$s" >&2; done
    die "deployment failed; see rollback instructions below"
  }
  sleep 2
done
log "all services healthy"

# ------------------------------------------------------------ 7. smoke test
log "running smoke test"
if ! "$RELEASE_DIR/scripts/smoke-test.sh"; then
  cat >&2 <<EOF

Smoke test FAILED. To roll back:

  docker compose -f $MANIFEST_DIR/previous.yml up -d

If the failure is in the database rather than the containers, restore instead:

  $RELEASE_DIR/scripts/restore.sh --latest

EOF
  exit 1
fi

log "deployment complete"
