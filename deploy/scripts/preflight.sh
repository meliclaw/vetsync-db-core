#!/usr/bin/env bash
# ==============================================================================
# preflight.sh — verify the host is ready BEFORE anything touches production.
#
# Read-only. Changes nothing. Exits non-zero on the first hard failure so it
# can gate a deployment pipeline.
#
#   ssh deploy@vetsync-vet-br-prd 'sudo /opt/vetsync/current/scripts/preflight.sh'
# ==============================================================================
set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/vetsync/prd.env}"
FAIL=0
WARN=0

pass() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ------------------------------------------------------------------ platform
head_ "Platform"
ARCH=$(dpkg --print-architecture)
[ "$ARCH" = "arm64" ] && pass "architecture $ARCH" \
  || fail "architecture is $ARCH; the pinned digests were verified for arm64"

command -v docker >/dev/null && pass "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
  || fail "docker not installed"
docker compose version >/dev/null 2>&1 && pass "compose plugin present" \
  || fail "docker compose plugin missing"

# ------------------------------------------------------------------- daemon
head_ "Docker daemon"
if [ -f /etc/docker/daemon.json ]; then
  jq -e '."log-opts"."max-size"' /etc/docker/daemon.json >/dev/null 2>&1 \
    && pass "log rotation configured" \
    || fail "no log rotation: container logs will fill the volume"
else
  fail "/etc/docker/daemon.json missing"
fi

# ------------------------------------------------------------------ storage
head_ "Filesystem"
for d in /srv/vetsync/postgres /srv/vetsync/storage /srv/vetsync/functions \
         /srv/vetsync/caddy/snippets /opt/vetsync/releases /etc/vetsync; do
  [ -d "$d" ] && pass "$d exists" || fail "$d missing"
done

mountpoint -q /srv \
  && pass "/srv is a dedicated mount" \
  || warn "/srv is on the root volume: data growth can take down the OS"

USED=$(df --output=pcent /srv 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$USED" ]; then
  [ "$USED" -lt 75 ] && pass "/srv at ${USED}% used" || fail "/srv at ${USED}% used"
fi

PERM=$(stat -c '%a' /etc/vetsync 2>/dev/null)
[ "$PERM" = "700" ] && pass "/etc/vetsync mode 700" || fail "/etc/vetsync mode $PERM, expected 700"

# --------------------------------------------------------------------- env
head_ "Environment file"
if [ -f "$ENV_FILE" ]; then
  P=$(stat -c '%a' "$ENV_FILE")
  [ "$P" = "600" ] && pass "$ENV_FILE mode 600" || fail "$ENV_FILE mode $P, expected 600"

  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a

  for v in POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY \
           SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY \
           REALTIME_DB_ENC_KEY DASHBOARD_PASSWORD SMTP_HOST \
           SUPABASE_PUBLIC_URL API_EXTERNAL_URL SITE_URL; do
    [ -n "${!v:-}" ] && pass "$v set" || fail "$v empty"
  done

  case "${SUPABASE_PUBLIC_URL:-}" in
    https://*) pass "SUPABASE_PUBLIC_URL uses https" ;;
    *)         fail "SUPABASE_PUBLIC_URL is '${SUPABASE_PUBLIC_URL:-}' — must be the public https URL" ;;
  esac
  case "${SITE_URL:-}" in
    *127.0.0.1*|*localhost*) fail "SITE_URL still points at loopback: auth redirects will break" ;;
    https://*)               pass "SITE_URL uses https" ;;
  esac
  [ "${POSTGRES_PORT:-}" = "5432" ] && pass "POSTGRES_PORT=5432" \
    || warn "POSTGRES_PORT=${POSTGRES_PORT:-unset}; 5432 expected in production"
else
  fail "$ENV_FILE missing"
fi

# ---------------------------------------------------------------- functions
head_ "Edge functions artifact"
FN="${VETSYNC_FUNCTIONS_DIR:-/srv/vetsync/functions/current}"
if [ -e "$FN" ]; then
  pass "$FN present"
  [ -f "$FN/main/index.ts" ] && pass "main router present" \
    || fail "main/index.ts missing: edge-runtime will not start"
  N=$(find "$FN" -maxdepth 1 -mindepth 1 -type d | wc -l)
  [ "$N" -gt 10 ] && pass "$N function directories" || warn "only $N function directories"
else
  fail "$FN missing"
fi

# ------------------------------------------------------------------ network
head_ "Public exposure"
if command -v ss >/dev/null; then
  # Not public, and must not be flagged as such:
  #   127.0.0.0/8      loopback, incl. systemd-resolved on .53 and .54
  #   ::1              IPv6 loopback
  #   100.64.0.0/10    Tailscale CGNAT range
  #   fd7a:115c:a1e0:: Tailscale IPv6 ULA prefix
  #   %lo              interface-scoped loopback notation
  BAD=$(ss -tlnH 2>/dev/null | awk '{print $4}' \
        | grep -Ev '^(127\.|\[?::1\]?|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|\[fd7a:115c:a1e0)' \
        | grep -Ev '%lo:' \
        | grep -Ev ':(22|80|443)$' || true)
  if [ -z "$BAD" ]; then
    pass "only 22/80/443 listen on public interfaces"
  else
    fail "unexpected public listeners:"
    printf '        %s\n' $BAD
  fi
fi

# --------------------------------------------------------------- host safety
head_ "Host safety"
if [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -gt 0 ]; then
  pass "swap configured ($(free -h | awk '/Swap/{print $2}'))"
else
  fail "no swap: a Postgres spike will be OOM-killed instead of degrading"
fi

systemctl is-active --quiet fail2ban 2>/dev/null \
  && pass "fail2ban active" \
  || warn "fail2ban not active: SSH is exposed on 0.0.0.0:22"

if grep -rqE '^\s*PermitRootLogin\s+no' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
  pass "root SSH login disabled"
else
  warn "PermitRootLogin not set to no: root can still log in with a key"
fi

id deploy >/dev/null 2>&1 \
  && pass "deploy user exists" \
  || warn "no 'deploy' user: deployments would run as root"

# ---------------------------------------------------------------- tailscale
head_ "Tailscale"
if command -v tailscale >/dev/null; then
  if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
    pass "tailscaled running as $(tailscale status --json | jq -r '.Self.DNSName')"
  else
    warn "tailscale installed but not connected: run 'sudo tailscale up --ssh'"
  fi
else
  warn "tailscale not installed: Studio has no safe access path"
fi

# ------------------------------------------------------------------- verdict
head_ "Result"
printf '  %d failure(s), %d warning(s)\n\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
