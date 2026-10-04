#!/usr/bin/env bash
# ==============================================================================
# host-bootstrap.sh — Phase 3 host provisioning, one auditable step at a time.
#
# Every run appends to /var/log/vetsync/provisioning.log with a timestamp, the
# operator, the step, the exact commands and their output. Nothing is silent.
#
#   ./host-bootstrap.sh --list
#   ./host-bootstrap.sh --step 1 --dry-run     # print, change nothing
#   ./host-bootstrap.sh --step 1               # execute
#
# Every step is idempotent: re-running is a no-op, not a duplicate.
#
# Step 5 (separate data volume) is intentionally absent. The operator decided
# on 2026-08-09 to accept a single volume with moderate monitoring, so the disk
# guard in step 5 replaces it.
# ==============================================================================
set -uo pipefail

LOG_DIR=/var/log/vetsync
LOG="$LOG_DIR/provisioning.log"
DRY=0
STEP=""

usage() {
  cat <<'EOF'
usage: host-bootstrap.sh --step <n> [--dry-run]
       host-bootstrap.sh --list

steps:
  1  docker daemon.json (log rotation, address pool) + restart docker
  2  8 GB swap + kernel tuning
  3  directory layout + /etc/vetsync mode 700
  4  deploy user with an ed25519 authorized key
  5  disk guard timer (single-volume monitoring)
  6  fail2ban + PermitRootLogin no        <-- run last, verify step 4 first
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --step) STEP="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --list) usage; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$STEP" ] || { usage; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

mkdir -p "$LOG_DIR"; chmod 750 "$LOG_DIR"

audit() { printf '%s [step %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STEP" "$*" >> "$LOG"; }
say()   { printf '  %s\n' "$*"; }
ok()    { printf '  \033[32mOK\033[0m    %s\n' "$*"; audit "OK: $*"; }
skip()  { printf '  \033[36mSKIP\033[0m  %s\n' "$*"; audit "SKIP: $*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# run <description> <<'CMD' ... CMD
run() {
  local desc="$1"; shift
  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m %s\n' "$desc"
    printf '        $ %s\n' "$*"
    return 0
  fi
  audit "EXEC: $desc :: $*"
  local out rc
  out=$("$@" 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/        /' && audit "OUT: $out"
  if [ $rc -eq 0 ]; then ok "$desc"; else
    printf '  \033[31mFAIL\033[0m  %s (rc=%d)\n' "$desc" "$rc"; audit "FAIL: $desc rc=$rc"; return $rc
  fi
}

write_file() {
  local path="$1" mode="$2" content="$3" desc="$4"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    skip "$desc (already current)"; return 0
  fi
  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m %s\n' "$desc"
    printf '        write %s (mode %s):\n' "$path" "$mode"
    printf '%s\n' "$content" | sed 's/^/        | /'
    [ -f "$path" ] && printf '        (existing file would be backed up)\n'
    return 0
  fi
  if [ -f "$path" ]; then
    cp -a "$path" "${path}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    audit "BACKUP: $path -> ${path}.bak.*"
  fi
  install -m "$mode" /dev/stdin "$path" <<<"$content"
  ok "$desc"
}

audit "=== begin step $STEP (dry_run=$DRY) by ${SUDO_USER:-$(id -un)} from ${SSH_CLIENT%% *} ==="

case "$STEP" in

# ------------------------------------------------------------------------ 1
1)
  head_ "Step 1 — Docker daemon: log rotation and address pool"
  say "Without max-size, container logs grow unbounded and fill the single volume."
  write_file /etc/docker/daemon.json 0644 '{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "userland-proxy": false,
  "default-address-pools": [
    { "base": "172.30.0.0/16", "size": 24 }
  ]
}' "docker daemon.json"

  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m restart docker (no containers running, so no impact)\n'
  else
    run "validate daemon.json" jq -e . /etc/docker/daemon.json >/dev/null \
      || { echo "invalid JSON, not restarting docker" >&2; exit 1; }
    run "restart docker" systemctl restart docker
    run "verify docker" docker info --format 'log-driver={{.LoggingDriver}}'
  fi
  ;;

# ------------------------------------------------------------------------ 2
2)
  head_ "Step 2 — 8 GB swap and kernel tuning"
  say "16 GB RAM with Postgres at 7 GB and no swap means the OOM killer, not degradation."
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    skip "swap already active: $(free -h | awk '/Swap/{print $2}')"
  else
    run "allocate /swapfile (8 GB)" fallocate -l 8G /swapfile
    run "chmod 600 /swapfile" chmod 600 /swapfile
    run "mkswap" mkswap /swapfile
    run "swapon" swapon /swapfile
    if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
      if [ "$DRY" -eq 1 ]; then printf '  \033[33mWOULD\033[0m append /swapfile to /etc/fstab\n'
      else cp -a /etc/fstab "/etc/fstab.bak.$(date -u +%Y%m%dT%H%M%SZ)"
           echo '/swapfile none swap sw 0 0' >> /etc/fstab; ok "persisted in /etc/fstab"; fi
    else skip "/swapfile already in /etc/fstab"; fi
  fi

  # overcommit_memory stays at 0 (heuristic). Strict mode (2) is right for a
  # dedicated Postgres host, but BEAM (Realtime, Supavisor) and Deno reserve
  # large virtual regions; a strict CommitLimit surfaces as opaque allocation
  # failures. The ceiling here is mem_limit plus swap.
  write_file /etc/sysctl.d/99-vetsync.conf 0644 'vm.swappiness = 10
vm.overcommit_memory = 0
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
fs.file-max = 200000' "sysctl tuning"
  [ "$DRY" -eq 0 ] && run "apply sysctl" sysctl --system
  ;;

# ------------------------------------------------------------------------ 3
3)
  head_ "Step 3 — directory layout, code and data separated"
  for d in /opt/vetsync/releases \
           /srv/vetsync/postgres /srv/vetsync/storage /srv/vetsync/snippets \
           /srv/vetsync/pg-wal-archive /srv/vetsync/functions \
           /srv/vetsync/caddy/data /srv/vetsync/caddy/config /srv/vetsync/caddy/snippets \
           /srv/vetsync/manifests /var/backups/vetsync; do
    if [ -d "$d" ]; then skip "$d exists"; else run "create $d" mkdir -p "$d"; fi
  done

  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m chmod 700 /etc/vetsync; chown 100:101 postgres dirs\n'
  else
    run "create /etc/vetsync" mkdir -p /etc/vetsync
    run "chmod 700 /etc/vetsync" chmod 700 /etc/vetsync
    # uid 100 / gid 101 = postgres inside supabase/postgres:17.6 (verified with
    # `docker run --rm --entrypoint sh <image> -c "id postgres"`). Do NOT guess
    # this: a wrong owner makes Postgres fail on PGDATA with permission denied.
    run "own PGDATA to postgres uid" chown -R 100:101 /srv/vetsync/postgres /srv/vetsync/pg-wal-archive
    run "chmod 700 PGDATA" chmod 700 /srv/vetsync/postgres
  fi
  ;;

# ------------------------------------------------------------------------ 4
4)
  head_ "Step 4 — deploy user"
  say "Deployments must not run as root. Membership in docker is already"
  say "root-equivalent, so this is a dedicated account, not a person's login."
  PUBKEY_FILE="${DEPLOY_PUBKEY_FILE:-/tmp/vetsync_deploy.pub}"
  [ -f "$PUBKEY_FILE" ] || { echo "  public key not found at $PUBKEY_FILE" >&2; exit 1; }
  grep -q '^ssh-ed25519 ' "$PUBKEY_FILE" || { echo "  not an ed25519 public key" >&2; exit 1; }

  if id deploy >/dev/null 2>&1; then skip "user deploy exists"
  else run "create user deploy" useradd -m -s /bin/bash -G docker deploy; fi

  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m install authorized_keys and a narrow sudoers rule\n'
    printf '        key: %s\n' "$(awk '{print $1" "substr($2,1,24)"..."$3}' "$PUBKEY_FILE")"
  else
    install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
    install -m 600 -o deploy -g deploy "$PUBKEY_FILE" /home/deploy/.ssh/authorized_keys
    ok "authorized_keys installed"
    write_file /etc/sudoers.d/vetsync-deploy 0440 'deploy ALL=(ALL) NOPASSWD:/usr/bin/systemctl restart docker
deploy ALL=(ALL) NOPASSWD:/usr/bin/systemctl reload docker' "sudoers rule"
    run "validate sudoers" visudo -cf /etc/sudoers.d/vetsync-deploy
    run "lock password login" passwd -l deploy
  fi
  ;;

# ------------------------------------------------------------------------ 5
5)
  head_ "Step 5 — disk guard (single volume, moderate monitoring)"
  say "Decision of 2026-08-09: one volume, no separate /srv device. The OS and"
  say "the data share 138 GB, so unbounded growth is an availability risk."
  write_file /usr/local/bin/vetsync-disk-guard 0755 '#!/usr/bin/env bash
set -euo pipefail
WARN=${1:-75}
CRIT=${2:-85}
USED=$(df --output=pcent / | tail -1 | tr -dc "0-9")
BIG=$(du -sh /srv/vetsync/* /var/lib/docker 2>/dev/null | sort -rh | head -5 | tr "\n" "; ")
if [ "$USED" -ge "$CRIT" ]; then
  logger -t vetsync-disk-guard -p daemon.crit "CRITICAL / at ${USED}% | ${BIG}"
  exit 2
elif [ "$USED" -ge "$WARN" ]; then
  logger -t vetsync-disk-guard -p daemon.warning "WARNING / at ${USED}% | ${BIG}"
  exit 1
fi
logger -t vetsync-disk-guard -p daemon.info "/ at ${USED}%"
exit 0' "disk guard script"

  write_file /etc/systemd/system/vetsync-disk-guard.service 0644 '[Unit]
Description=VetSync disk usage guard
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vetsync-disk-guard 75 85' "disk guard service"

  write_file /etc/systemd/system/vetsync-disk-guard.timer 0644 '[Unit]
Description=Run VetSync disk guard every 15 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target' "disk guard timer"

  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m enable vetsync-disk-guard.timer\n'
  else
    run "reload systemd" systemctl daemon-reload
    run "enable timer" systemctl enable --now vetsync-disk-guard.timer
    run "first run" /usr/local/bin/vetsync-disk-guard 75 85
  fi
  ;;

# ------------------------------------------------------------------------ 6
6)
  head_ "Step 6 — fail2ban and root SSH lockout"
  say "LAST on purpose. Verify 'ssh deploy@host' works BEFORE running this,"
  say "or the only way back in is the Scaleway serial console."
  if [ "$DRY" -eq 0 ]; then
    id deploy >/dev/null 2>&1 || { echo "  deploy user missing — run step 4 first" >&2; exit 1; }
    [ -s /home/deploy/.ssh/authorized_keys ] || { echo "  deploy has no authorized_keys" >&2; exit 1; }
    command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1 \
      || { echo "  tailscale not connected — refusing to remove the fallback path" >&2; exit 1; }
  fi

  if ! dpkg -s fail2ban >/dev/null 2>&1; then
    run "install fail2ban" apt-get install -y -q fail2ban
  else skip "fail2ban installed"; fi

  write_file /etc/fail2ban/jail.d/vetsync.conf 0644 '[sshd]
enabled  = true
backend  = systemd
maxretry = 3
findtime = 10m
bantime  = 1h
# Never ban the tailnet: it is the recovery path.
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10 fd7a:115c:a1e0::/48' "fail2ban jail"

  write_file /etc/ssh/sshd_config.d/99-vetsync.conf 0644 'PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
AllowUsers deploy' "sshd hardening"

  if [ "$DRY" -eq 1 ]; then
    printf '  \033[33mWOULD\033[0m validate sshd config, restart sshd and fail2ban\n'
    printf '        NOTE: root SSH stops working. Access becomes deploy@ or tailscale.\n'
  else
    run "validate sshd config" sshd -t
    run "enable fail2ban" systemctl enable --now fail2ban
    run "restart fail2ban" systemctl restart fail2ban
    run "restart sshd" systemctl restart ssh
    say "root SSH is now closed. Verify from another terminal BEFORE closing this one:"
    say "  ssh deploy@vetsync-vet-br-prd 'id -un'"
  fi
  ;;

*)
  echo "unknown step: $STEP" >&2; usage; exit 2 ;;
esac

audit "=== end step $STEP (dry_run=$DRY) ==="
printf '\n  audit log: %s\n' "$LOG"
