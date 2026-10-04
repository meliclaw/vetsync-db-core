#!/usr/bin/env bash
# ==============================================================================
# restore.sh — restore database + storage objects from an encrypted backup.
#
# DESTRUCTIVE. Overwrites the target database and the storage tree.
# Requires two explicit confirmations and refuses to run against the live
# production project unless VETSYNC_RESTORE_PRODUCTION=yes is also set.
#
#   ./restore.sh --list
#   ./restore.sh --latest                       # into a restore-test project
#   ./restore.sh --file 20260809T120000Z_scheduled.tar.age
#
# After ANY restore the persisted Postgres roles must be resynchronised with
# the env, or Auth/PostgREST/Storage/Supavisor fail with SQLSTATE 28P01.
# This script does that automatically at the end.
# ==============================================================================
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/vetsync/prd.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/vetsync/current/compose.prod.yml}"
STAGING="${STAGING:-/var/backups/vetsync}"
AGE_KEY="${AGE_KEY:-/etc/vetsync/backup-age.key}"

set -a; . "$ENV_FILE"; set +a

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

s3() {
  AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY" \
  aws --endpoint-url "$BACKUP_S3_ENDPOINT" "$@"
}

FILE=""
case "${1:-}" in
  --list)
    s3 s3 ls "s3://${BACKUP_S3_BUCKET}/" | sort
    exit 0 ;;
  --latest)
    FILE=$(s3 s3 ls "s3://${BACKUP_S3_BUCKET}/" | sort | tail -1 | awk '{print $4}') ;;
  --file)
    FILE="${2:?--file needs a name}" ;;
  *)
    echo "usage: restore.sh --list | --latest | --file <name>" >&2; exit 2 ;;
esac

[ -n "$FILE" ] || die "no backup selected"

# --------------------------------------------------------------- guardrails
if [ "${COMPOSE_PROJECT_NAME:-}" = "vetsync-prd" ] && [ "${VETSYNC_RESTORE_PRODUCTION:-}" != "yes" ]; then
  die "target is the live production project. Set VETSYNC_RESTORE_PRODUCTION=yes to proceed."
fi
[ "${VETSYNC_RESTORE_CONFIRM:-}" = "yes" ] \
  || die "set VETSYNC_RESTORE_CONFIRM=yes to acknowledge this overwrites data"
[ -f "$AGE_KEY" ] || die "age private key not found at $AGE_KEY"

log "restoring $FILE into project ${COMPOSE_PROJECT_NAME:-default}"

# ------------------------------------------------------- fetch and decrypt
WORK=$(mktemp -d "${STAGING}/restore.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

log "downloading"
s3 s3 cp "s3://${BACKUP_S3_BUCKET}/${FILE}" "${WORK}/backup.tar.age" --only-show-errors

log "decrypting"
age -d -i "$AGE_KEY" < "${WORK}/backup.tar.age" | tar -C "$WORK" -x

[ -f "${WORK}/database.dump" ] || die "archive contains no database.dump"
log "manifest: $(cat "${WORK}/manifest.json")"

# ------------------------------------------------------------------ database
log "ensuring the database is up"
docker compose -f "$COMPOSE_FILE" up -d db
for i in $(seq 1 60); do
  docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U postgres >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && die "database did not become ready"
  sleep 2
done

log "restoring roles"
docker compose -f "$COMPOSE_FILE" exec -T db \
  psql -U postgres -v ON_ERROR_STOP=0 -q < "${WORK}/roles.sql" >/dev/null 2>&1 || true

log "restoring schema and data (this takes a while)"
# --clean --if-exists makes the restore idempotent; pg_trgm is required by
# the GIN trigram indexes in the VetSync schema.
docker compose -f "$COMPOSE_FILE" exec -T db \
  psql -U postgres -d "${POSTGRES_DB}" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" >/dev/null

docker compose -f "$COMPOSE_FILE" exec -T db \
  pg_restore -U postgres -d "${POSTGRES_DB}" \
    --clean --if-exists --no-owner --no-acl --jobs=3 \
  < "${WORK}/database.dump" 2>&1 | grep -vE 'does not exist, skipping' || true

# ------------------------------------------------------------------ storage
if [ -f "${WORK}/storage.tar" ]; then
  log "restoring storage objects"
  # Objects and storage.objects rows must move together, or every report,
  # radiograph and consent form becomes a dangling reference.
  rm -rf /srv/vetsync/storage.old
  [ -d /srv/vetsync/storage ] && mv /srv/vetsync/storage /srv/vetsync/storage.old
  tar -C /srv/vetsync -xf "${WORK}/storage.tar"
  log "previous objects kept at /srv/vetsync/storage.old"
else
  log "archive has no storage objects (db-only backup) — skipping"
fi

# ------------------------------------------------- roles <-> env resynchronise
# MANDATORY. The dump carries the role passwords from the SOURCE system;
# without this step every service fails 28P01 against the current env.
log "synchronising service roles with the current environment"
docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'postgres','supabase_admin','supabase_auth_admin','supabase_storage_admin',
    'supabase_functions_admin','authenticator','pgbouncer'
  ] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', r, '${POSTGRES_PASSWORD}');
    END IF;
  END LOOP;
END \$\$;
SQL

# ----------------------------------------------------------- bring stack up
log "recreating dependent services"
docker compose -f "$COMPOSE_FILE" up -d
docker compose -f "$COMPOSE_FILE" restart auth rest storage supavisor realtime

log "waiting for health"
sleep 20

log "verifying"
/opt/vetsync/current/scripts/smoke-test.sh || die "restore completed but smoke test failed"

log "restore complete"
