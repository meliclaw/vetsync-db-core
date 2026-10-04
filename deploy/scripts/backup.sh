#!/usr/bin/env bash
# ==============================================================================
# backup.sh — encrypted, off-box backup of database + storage objects.
#
# Postgres rows and Storage files are ONE unit. Restoring the database without
# the objects leaves dangling references across every report, DICOM image and
# surgical consent in the system, so both are captured in the same run and
# share a manifest.
#
#   ./backup.sh                       # routine backup
#   ./backup.sh --tag pre-deploy-x    # labelled backup
#   ./backup.sh --db-only             # skip objects (faster pre-deploy gate)
# ==============================================================================
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/vetsync/prd.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/vetsync/current/compose.prod.yml}"
STAGING="${STAGING:-/var/backups/vetsync}"

set -a; . "$ENV_FILE"; set +a

TAG="scheduled"
DB_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --db-only) DB_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${BACKUP_AGE_RECIPIENT:?BACKUP_AGE_RECIPIENT must be set}"
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET must be set}"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
PREFIX="${STAMP}_${TAG}"
WORK="${STAGING}/${PREFIX}"
mkdir -p "$WORK"

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------- 1. database
# Custom format: compressed, selective on restore, and portable across CPU
# architectures. A filesystem copy of PGDATA is NOT a substitute.
log "dumping database"
docker compose -f "$COMPOSE_FILE" exec -T db \
  pg_dump -U postgres -d "${POSTGRES_DB}" -Fc --no-owner --no-acl \
  > "${WORK}/database.dump"

SIZE=$(stat -c '%s' "${WORK}/database.dump")
[ "$SIZE" -gt 100000 ] || { echo "dump is only ${SIZE} bytes — refusing" >&2; exit 1; }
log "dump: $(numfmt --to=iec "$SIZE")"

# Verify the dump is readable BEFORE trusting it. A dump that pg_restore
# cannot list is not a backup.
log "verifying dump integrity"
docker compose -f "$COMPOSE_FILE" exec -T db pg_restore --list /dev/stdin \
  < "${WORK}/database.dump" > "${WORK}/database.toc" \
  || { echo "dump failed pg_restore --list" >&2; exit 1; }
TOC_LINES=$(wc -l < "${WORK}/database.toc")
log "table of contents: ${TOC_LINES} entries"

# ------------------------------------------------------ 2. roles and globals
log "dumping roles"
docker compose -f "$COMPOSE_FILE" exec -T db \
  pg_dumpall -U postgres --roles-only > "${WORK}/roles.sql"

# --------------------------------------------------------- 3. storage objects
if [ "$DB_ONLY" -eq 0 ]; then
  log "archiving storage objects"
  tar -C /srv/vetsync -cf "${WORK}/storage.tar" storage
  log "storage: $(numfmt --to=iec "$(stat -c '%s' "${WORK}/storage.tar")")"
fi

# ------------------------------------------------------------- 4. WAL archive
if [ -d /srv/vetsync/pg-wal-archive ] && [ -n "$(ls -A /srv/vetsync/pg-wal-archive 2>/dev/null)" ]; then
  log "archiving WAL segments"
  tar -C /srv/vetsync -cf "${WORK}/wal.tar" pg-wal-archive
fi

# ---------------------------------------------------------------- 5. manifest
cat > "${WORK}/manifest.json" <<EOF
{
  "timestamp": "${STAMP}",
  "tag": "${TAG}",
  "host": "$(hostname)",
  "postgres_image": "$(docker compose -f "$COMPOSE_FILE" config | awk '/supabase\/postgres/{print $2; exit}')",
  "database_bytes": ${SIZE},
  "toc_entries": ${TOC_LINES},
  "includes_storage": $([ "$DB_ONLY" -eq 0 ] && echo true || echo false)
}
EOF

# --------------------------------------------------------------- 6. encrypt
# Encrypted with an age PUBLIC key. The private key lives off this host, so
# root on the VPS cannot read the backups it produces.
log "encrypting"
tar -C "$WORK" -c . | age -r "$BACKUP_AGE_RECIPIENT" > "${STAGING}/${PREFIX}.tar.age"

# ---------------------------------------------------------------- 7. upload
log "uploading to object storage"
AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY" \
aws --endpoint-url "$BACKUP_S3_ENDPOINT" s3 cp \
  "${STAGING}/${PREFIX}.tar.age" \
  "s3://${BACKUP_S3_BUCKET}/${PREFIX}.tar.age" \
  --only-show-errors

rm -f "${STAGING}/${PREFIX}.tar.age"

# --------------------------------------------------- 8. prune the WAL archive
# Segments already captured can go; otherwise the archive grows without bound
# and eventually fills /srv.
find /srv/vetsync/pg-wal-archive -type f -mtime +2 -delete 2>/dev/null || true

log "backup complete: ${PREFIX}.tar.age"
