#!/usr/bin/env bash
# ==============================================================================
# package-functions.sh — build a versioned edge-functions artifact.
#
# Replaces the symlink farm in volumes-prd/functions/, which pointed at
# vetsync-os/src/supabase/functions — a path that no longer exists. All 66
# links were dead when checked on 2026-08-09, so the PRD stack could never have
# started from that tree.
#
# The artifact is assembled from TWO sources, because neither is complete:
#   1. vetsync-vet/supabase/functions   the 74 application functions + _shared
#   2. vetsync-db-core volumes/functions/main   the self-hosted Edge Runtime
#      router. `main/` exists in the app repo but is EMPTY, and edge-runtime
#      starts with `--main-service /home/deno/functions/main`, so without it
#      the container never comes up.
#
#   APP_FUNCTIONS=/path/to/vetsync-vet/supabase/functions ./package-functions.sh
#   APP_FUNCTIONS=... ./package-functions.sh --deploy HOST   # build, ship, activate
#
# APP_FUNCTIONS has no default: vetsync-vet moved once already (a hardcoded
# relative climb silently rotted after that move, 2026-10-07), so it's a
# required input instead of a guessed path.
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_FUNCTIONS="${APP_FUNCTIONS:?set APP_FUNCTIONS to the vetsync-vet/supabase/functions path}"
MAIN_ROUTER="${MAIN_ROUTER:-$HERE/volumes/functions/main}"
OUT_DIR="${OUT_DIR:-$HERE/.artifacts}"

DEPLOY_HOST=""
[ "${1:-}" = "--deploy" ] && DEPLOY_HOST="${2:?--deploy needs a host}"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$APP_FUNCTIONS" ] || die "app functions not found at $APP_FUNCTIONS"
[ -f "$MAIN_ROUTER/index.ts" ] || die "main router not found at $MAIN_ROUTER/index.ts"

SHA=$(git -C "$APP_FUNCTIONS" rev-parse --short HEAD 2>/dev/null || echo "nogit")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="functions-${SHA}"
STAGE="$OUT_DIR/$NAME"

log "source:  $APP_FUNCTIONS"
log "router:  $MAIN_ROUTER"
log "version: $SHA ($STAMP)"

rm -rf "$STAGE"
mkdir -p "$STAGE"

# --- copy, dereferencing symlinks so the artifact is self-contained --------
# -L matters: any surviving symlink would break the moment the artifact leaves
# this machine, which is exactly the failure mode being fixed.
# COPYFILE_DISABLE stops bsdtar on macOS from emitting AppleDouble "._*"
# sidecar files for extended attributes. Without it the artifact carries one
# per source file into a Linux container that has no use for them.
log "copying functions"
COPYFILE_DISABLE=1 tar -C "$APP_FUNCTIONS" -chf - . | tar -C "$STAGE" -xf -

# --- overlay the self-hosted router ---------------------------------------
log "overlaying main router"
rm -rf "$STAGE/main"
mkdir -p "$STAGE/main"
cp -R "$MAIN_ROUTER/." "$STAGE/main/"

# --- strip anything that must never reach the server ----------------------
find "$STAGE" \( -name '.DS_Store' -o -name '._*' -o -name '*.log' -o -name '.env' -o -name '.env.*' \
                 -o -name 'node_modules' -o -name '.git' \) -prune -exec rm -rf {} + 2>/dev/null || true

# --- verify ----------------------------------------------------------------
[ -f "$STAGE/main/index.ts" ] || die "main/index.ts missing after assembly"

COUNT=$(find "$STAGE" -maxdepth 2 -name 'index.ts' -not -path "$STAGE/main/*" | wc -l | tr -d ' ')
[ "$COUNT" -ge 50 ] || die "only $COUNT functions found; expected ~74"

if find "$STAGE" -name '._*' -o -name '.DS_Store' | grep -q .; then
  die "macOS metadata files survived the strip"
fi

if find "$STAGE" -type l | grep -q .; then
  die "artifact still contains symlinks: $(find "$STAGE" -type l | head -3)"
fi

# Secrets belong in /etc/vetsync/prd.env, never in a shipped artifact.
if grep -rlE 'sk_live_|SG\.[A-Za-z0-9_-]{20}|-----BEGIN [A-Z ]*PRIVATE KEY' "$STAGE" 2>/dev/null | grep -q .; then
  die "possible secret material inside the artifact — refusing to package"
fi

log "$COUNT functions + main router, no symlinks, no obvious secrets"

# --- package ---------------------------------------------------------------
TARBALL="$OUT_DIR/${NAME}.tar.gz"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$TARBALL" .
SIZE=$(du -h "$TARBALL" | cut -f1)
DIGEST=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)

log "artifact: $TARBALL ($SIZE)"
log "sha256:   $DIGEST"

# --- deploy ----------------------------------------------------------------
if [ -n "$DEPLOY_HOST" ]; then
  log "shipping to $DEPLOY_HOST"
  scp -q "$TARBALL" "root@${DEPLOY_HOST}:/tmp/${NAME}.tar.gz"

  ssh "root@${DEPLOY_HOST}" bash -s <<EOF
set -euo pipefail
# Verify in flight — a truncated upload must not become the live release.
ACTUAL=\$(sha256sum "/tmp/${NAME}.tar.gz" | cut -d' ' -f1)
[ "\$ACTUAL" = "$DIGEST" ] || { echo "digest mismatch: \$ACTUAL != $DIGEST" >&2; exit 1; }

rm -rf "/srv/vetsync/functions/${SHA}.new"
mkdir -p "/srv/vetsync/functions/${SHA}.new"
tar -C "/srv/vetsync/functions/${SHA}.new" -xzf "/tmp/${NAME}.tar.gz"
[ -f "/srv/vetsync/functions/${SHA}.new/main/index.ts" ] || { echo "main router missing after extract" >&2; exit 1; }

rm -rf "/srv/vetsync/functions/${SHA}"
mv "/srv/vetsync/functions/${SHA}.new" "/srv/vetsync/functions/${SHA}"

# Atomic swap: ln -sfn on a temp name then mv, so 'current' is never absent.
ln -sfn "/srv/vetsync/functions/${SHA}" "/srv/vetsync/functions/.current.tmp"
mv -Tf "/srv/vetsync/functions/.current.tmp" "/srv/vetsync/functions/current"

rm -f "/tmp/${NAME}.tar.gz"
echo "  active: \$(readlink /srv/vetsync/functions/current)"
echo "  functions: \$(find -L /srv/vetsync/functions/current -maxdepth 2 -name index.ts | wc -l)"
EOF
  log "deployed and activated"
fi
