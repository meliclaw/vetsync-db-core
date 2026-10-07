# VetSync PRD — Scaleway Deployment

Phase-by-phase implementation plan with an explicit validation gate at every
step. No phase proceeds while its gate is red.

> ⚠️ **Multi-tenant isolation, partially resolved:**
> [audit](../specs/VetSync%20RLS%20Audit%20and%20Remediation%20Plan.md) ·
> [database change log](../specs/VetSync%20DB%20Change%20Log%20—%20RLS%20Remediation.md).
> Anonymous access closed, 114 of 211 tables isolated. 97 remain; cutover is still blocked.

> Operational runbook (everything executed, verification, rollback):
> [`../specs/VetSync PRD Deployment Runbook.md`](../specs/VetSync%20PRD%20Deployment%20Runbook.md)

> English version of [`README.md`](README.md). Both describe the same plan;
> keep them in sync when either changes.

**Target:** Scaleway `BASIC2-A4C-16G` (ARM64 / Ampere Neoverse-N1), Ubuntu
24.04.4 LTS, AMS1 · `51.15.108.6` · tailnet `vetsync-vet-br-prd.tail48dc0d.ts.net`

---

## 0. Artifact index

| File | Role |
|---|---|
| [`compose.prod.yml`](compose.prod.yml) | Standalone production stack. Replaces the OrbStack override |
| [`caddy/Caddyfile`](caddy/Caddyfile) | TLS, host routing, API path allowlist |
| [`caddy/snippets/web-upstream.caddy`](caddy/snippets/web-upstream.caddy) | Frontend blue/green switch |
| [`api/kong.yml`](api/kong.yml) | Production Kong declarative config |
| [`api/kong-entrypoint.sh`](api/kong-entrypoint.sh) | Env substitution and opaque-key translation |
| [`pooler/pooler.exs`](pooler/pooler.exs) | Supavisor tenant provisioning |
| [`db/`](db/) | Postgres init SQL (roles, JWT, realtime, pooler, webhooks) |
| [`cloud-init/vetsync-prd.yaml`](cloud-init/vetsync-prd.yaml) | Hardened host bootstrap |
| [`terraform/`](terraform/) | OpenTofu: instance, IP, security group, bucket, IAM |
| [`env/prd.env.example`](env/prd.env.example) | Production environment template |
| [`scripts/host-bootstrap.sh`](scripts/host-bootstrap.sh) | Phase 3 provisioning, one auditable step at a time |
| [`scripts/preflight.sh`](scripts/preflight.sh) | Host readiness check before deploying |
| [`scripts/deploy-stack.sh`](scripts/deploy-stack.sh) | Controlled recreate of Supabase services |
| [`scripts/deploy-web.sh`](scripts/deploy-web.sh) | Frontend blue/green release |
| [`scripts/rollback-web.sh`](scripts/rollback-web.sh) | Return to the previous colour |
| [`scripts/backup.sh`](scripts/backup.sh) | Encrypted off-box backup (database + objects) |
| [`scripts/restore.sh`](scripts/restore.sh) | Restore plus mandatory role resynchronisation |
| [`scripts/smoke-test.sh`](scripts/smoke-test.sh) | Post-deploy verification |

In `vetsync-vet`: `Dockerfile`, `docker/nginx.conf`,
`docker/docker-entrypoint.d/10-runtime-config.sh`, `src/lib/runtimeConfig.ts`,
`.github/workflows/web-build-deploy.yml`.

---

## 1. Decisions already made

| Topic | Decision |
|---|---|
| Strategy | Blue/green for the frontend only · controlled recreate for Supabase · expand/contract for Postgres · **no canary** |
| Delivery | Mac → git → CI (ARM64) → registry → VPS pulls by digest |
| IaC | OpenTofu with the Scaleway provider |
| Objective | Minimal public surface, immutable releases, data separated from code |
| Access | SSH over Tailscale |
| Region | **AMS1**, confirmed 2026-08-09 |
| Storage | **Single volume** accepted, with moderate monitoring (decision 2026-08-09) |

### Verified, not assumed

Each of these was checked against the real thing rather than inferred:

- `BASIC2-A4C-16G` is ARM64 (Ampere). The host kernel reports `aarch64`,
  the CPU is `Neoverse-N1`.
- All **12 images** (11 Supabase plus Caddy) publish an `arm64` manifest.
  No architecture blocker.
- Every image is **pinned by digest** in `compose.prod.yml`. Tags are
  documentation only, and `deploy-stack.sh` refuses a floating tag.
- `kong.yml` passes `kong config parse` on the real Kong 3.9.1 binary
  (21 services). An earlier top-level YAML anchor was **rejected** by Kong
  and had to be moved onto the first plugin entry.
- Postgres inside `supabase/postgres:17.6` runs as **uid 100, gid 101** —
  not the 105/106 originally assumed. A wrong owner makes Postgres fail on
  PGDATA with permission denied.
- `docker compose config` renders exactly four published ports: Caddy on
  `0.0.0.0:80`, `:443/tcp`, `:443/udp`, and Kong on `127.0.0.1:8000`.
  Postgres and Supavisor publish nothing.

---

## 2. Target architecture

```
Internet
  │  Security group: stateful, inbound DROP
  │  443/tcp · 443/udp · 80/tcp · 41641/udp · 22 restricted
  ▼
Caddy ── the only process on the public interface
  ├── app.vetsync.com.br    ─┐
  ├── admin.vetsync.com.br  ─┴─→ web-blue | web-green   (edge network)
  └── api.vetsync.com.br     ──→ kong:8000  [PATH ALLOWLIST]
                                   │
Tailscale ── Studio ───────────────┤ 127.0.0.1:8000
                                   ▼  (core network)
        auth · rest · realtime · storage · imgproxy · meta · functions · studio
                                   ▼
                            supavisor → db
                                   ▼
                              /srv/vetsync
```

Filesystem layout — code and data strictly separated even though they share
one volume:

```
/opt/vetsync/releases/<sha>/   release code and configuration
/opt/vetsync/current ->        symlink to the active release
/srv/vetsync/postgres/         PGDATA (uid 100, mode 700)
/srv/vetsync/storage/          objects
/srv/vetsync/functions/<sha>/  versioned edge functions
/srv/vetsync/caddy/            Caddy state and the blue/green snippet
/srv/vetsync/manifests/        previous compose manifests, for rollback
/etc/vetsync/prd.env           secrets, 0600 root:root
/var/backups/vetsync/          staging before upload
/var/log/vetsync/              provisioning audit log
```

---

## 3. Phases

### Phase 0 — Blocking decisions · ✅ closed

| Item | Status |
|---|---|
| Region | ✅ **AMS1** |
| LGPD paperwork | ⚠️ **Open.** Brazilian clinical data hosted in the Netherlands. LGPD Art. 33 requires a documented legal basis and safeguards, plus a processor agreement with Scaleway. This is a document, not code, and it must exist before real patient data moves. Expect ~200 ms RTT from Brazil (126 ms measured over the tailnet) |
| Apex and MX | ✅ Stay on HostGator (`69.6.215.134`). Untouched |
| `console.vetsync.com.br` | ✅ No public A record. Studio over Tailscale only |
| Data volume | ✅ Single volume accepted, with the disk guard from Phase 3 |

---

### Phase 1 — Prepare the repositories · ✅ executed 2026-08-09

```bash
cd /Volumes/Backup/Projects/src/heyzify/data-platform/data-core/wapnet/vetsync-db-core
chmod +x deploy/scripts/*.sh
```

Secrets excluded from git (already applied to `.gitignore`):

```
deploy/terraform/*.tfvars
deploy/terraform/backend.hcl
deploy/terraform/.terraform/
deploy/terraform/*.tfstate*
deploy/env/prd.env
```

Changes applied to `vetsync-vet`. It turned out to be **19 files**, not 4:
the sweep found 11 more reading `import.meta.env.VITE_SUPABASE_*` directly,
several with a fallback to the legacy Supabase Cloud project. Detail and
verification are in the [runbook](../specs/VetSync%20PRD%20Deployment%20Runbook.md#41-fase-1--aplicación-vetsync-vet).

1. **`vite.config.ts:17`** — `mcpPlugin()` currently ships in the production
   bundle because it is not gated on mode:
   ```diff
   -    mcpPlugin(),
   +    mode === "development" && mcpPlugin(),
   ```
2. **`index.html`** — load the runtime config before the module bundle. It has
   to be a synchronous script tag; a `fetch()` would race module evaluation:
   ```html
   <script src="/config.js"></script>
   <script type="module" src="/src/main.tsx"></script>
   ```
3. **`src/integrations/supabase/client.ts`** — read from `runtimeConfig`:
   ```ts
   import { runtimeConfig } from '@/lib/runtimeConfig';
   export const supabase = createClient<Database>(
     runtimeConfig.SUPABASE_URL,
     runtimeConfig.SUPABASE_PUBLISHABLE_KEY,
     { auth: { storage: localStorage, persistSession: true, autoRefreshToken: true } }
   );
   ```
   > That file is marked "automatically generated". Confirm Lovable does not
   > regenerate it and drop the change; if it does, move the client elsewhere.
4. **PWA** — decide. `VitePWA({ selfDestroying: true })` currently emits a
   service worker whose only job is to unregister itself, so the PWA does not
   work today. Either enable it — in which case the SW constrains blue/green —
   or remove the dependency.

**Gate 1:** `npx tsc --noEmit && npm run lint && npx vitest run` green, and
`docker compose -f deploy/compose.prod.yml config -q` clean.

---

### Phase 2 — Infrastructure (OpenTofu) · 🔄 import done, `apply` pending

```bash
cd deploy/terraform
cp prd.tfvars.example prd.tfvars      # project_id, admin_ssh_cidrs
cp backend.hcl.example backend.hcl    # state bucket

export SCW_ACCESS_KEY=... SCW_SECRET_KEY=... SCW_DEFAULT_ORGANIZATION_ID=...

tofu init -backend-config=backend.hcl
tofu plan  -var-file=prd.tfvars
tofu apply -var-file=prd.tfvars
```

> The current instance was created by hand. To bring it under IaC without
> recreating it, import **before** any apply, or Tofu will build a second one:
> ```bash
> tofu import -var-file=prd.tfvars scaleway_instance_server.main nl-ams-1/5a502bd5-fa8d-49fa-8544-52959aad...
> ```

> Because the single-volume decision stands, either remove
> `scaleway_block_volume.data` from `main.tf` or leave it unattached. Do not
> let the plan silently create a volume nobody mounts.

**Gate 2:**
```bash
tofu output public_ipv4                # 51.15.108.6
nmap -Pn -p- 51.15.108.6 | grep open   # exactly 22, 80, 443
```
Scaleway's auto-created security group is **stateless**; confirm the instance
uses the dedicated stateful one, not the default.

---

### Phase 3 — Host provisioning · ✅ executed 2026-08-09

Run as discrete, idempotent, audited steps. Every run appends to
`/var/log/vetsync/provisioning.log` with a UTC timestamp, the operator, the
originating SSH address, the exact command and its output. Any file that gets
overwritten is copied to `<file>.bak.<timestamp>` first.

```bash
./host-bootstrap.sh --list
./host-bootstrap.sh --step 1 --dry-run   # print, change nothing
./host-bootstrap.sh --step 1             # execute
```

| Step | What it does | Status |
|---|---|---|
| 1 | `daemon.json`: log rotation, `userland-proxy: false`, address pool `172.30.0.0/16`; validate JSON then restart Docker | ✅ |
| 2 | 8 GB swap, `vm.swappiness=10`, socket and file-descriptor limits | ✅ |
| 3 | Directory layout, `/etc/vetsync` mode 700, PGDATA owned by uid 100 | ✅ |
| 4 | `deploy` user, ed25519 key, narrow sudoers, password login locked | ✅ |
| 5 | Disk guard timer every 15 min (warn 75 %, critical 85 %) | ✅ |
| 6 | `fail2ban` + `PermitRootLogin no` | ⏸ pending confirmation |

Two design notes worth keeping:

- **`vm.overcommit_memory` stays at `0`.** Strict mode (`2`) is correct for a
  dedicated Postgres host, but BEAM (Realtime, Supavisor) and Deno reserve
  large virtual regions here. A strict `CommitLimit` surfaces as opaque
  allocation failures. The real ceiling is `mem_limit` plus swap.
- **`default-address-pools` is pinned.** Without it Docker picks `172.17+`
  dynamically and can collide with VPN or customer ranges. The fail2ban
  `ignoreip` and the nftables rules assume `172.30.0.0/16`.

Step 6 is deliberately last, and the script refuses to run it unless the
`deploy` user exists, has an `authorized_keys`, and Tailscale is connected —
otherwise the only way back in is the Scaleway serial console.

**Gate 3:** `preflight.sh` reports 0 failures.

---

### Phase 4 — Versioned artifacts

Edge functions ship as a tarball, not as a symlink into another repository.
`package-functions.sh` requires `APP_FUNCTIONS` explicitly (no default) —
a hardcoded relative path to `vetsync-vet` already rotted once when the
repo moved (2026-10-07). `vetsync-vet` now lives at
`/Volumes/Backup/Projects/src/wapnet/vetsync-ecosystem/src/vetsync-vet`.

```bash
VETSYNC_VET=/Volumes/Backup/Projects/src/wapnet/vetsync-ecosystem/src/vetsync-vet
SHA=$(git -C "$VETSYNC_VET" rev-parse --short HEAD)
tar -C "$VETSYNC_VET/supabase" -czf functions-$SHA.tar.gz functions
scp functions-$SHA.tar.gz deploy@vetsync-vet-br-prd:/tmp/

ssh deploy@vetsync-vet-br-prd bash -s <<EOF
  mkdir -p /srv/vetsync/functions/$SHA
  tar -C /srv/vetsync/functions/$SHA --strip-components=1 -xzf /tmp/functions-$SHA.tar.gz
  ln -sfn /srv/vetsync/functions/$SHA /srv/vetsync/functions/current
EOF
```

Stack release — the `deploy/` tree is self-contained, so this is one rsync:

```bash
SHA=$(git rev-parse --short HEAD)
rsync -a --delete deploy/ deploy@vetsync-vet-br-prd:/opt/vetsync/releases/$SHA/
ssh deploy@vetsync-vet-br-prd "ln -sfn /opt/vetsync/releases/$SHA /opt/vetsync/current"
```

**Gate 4:** `preflight.sh` confirms `main/index.ts` and more than ten function
directories.

---

### Phase 5 — Database · 🚫 blocked by the RLS remediation

Bring up `db` alone, then restore **logically**. Do not copy `PGDATA` at the
filesystem level: it is fragile across version, locale/ICU, checksums and WAL
state, and a correct `pg_dump -Fc` path already exists.

```bash
set -a && . /etc/vetsync/prd.env && set +a
docker compose -f /opt/vetsync/current/compose.prod.yml up -d db
docker compose -f /opt/vetsync/current/compose.prod.yml exec db pg_isready -U postgres

export VETSYNC_RESTORE_CONFIRM=yes VETSYNC_RESTORE_PRODUCTION=yes
/opt/vetsync/current/scripts/restore.sh --file <backup>.tar.age
```

`restore.sh` enables `pg_trgm` (the backup's GIN trigram indexes require it)
and **resynchronises the service roles** with the current environment at the
end. Without that step, Auth, PostgREST, Storage and Supavisor all fail with
SQLSTATE `28P01` against a database that is otherwise perfectly healthy.

> **Before Phase 5.** The RLS remediation was applied to the local stack
> **without migrations**. Restoring the dump as-is on the VPS brings RLS only
> where the dump carries it. Convert `.artifacts/step-b*.sql` into versioned
> migrations and apply them after the restore, or the gate below fails.

**Gate 5:**
```sql
-- expect roughly 158
select count(*) from information_schema.tables where table_schema='public';

-- MUST be 0: a public table without RLS exposes data across organizations
select count(*) from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;
```

---

### Phase 6 — Supabase stack

```bash
/opt/vetsync/current/scripts/deploy-stack.sh
```

The script takes a backup first (GoTrue and Storage both migrate schema at
startup), saves the previous manifest for rollback, refuses any image that is
not pinned by digest, recreates, waits for health, and runs the smoke test.

**Gate 6:** `smoke-test.sh` green, including the *Studio isolation* block.

---

### Phase 7 — Frontend

```bash
gh workflow run web-build-deploy.yml -f deploy=true
```

`deploy-web.sh` starts the candidate colour, probes it directly **before** any
traffic moves, flips the Caddy snippet, reloads in place, and reverts
automatically if the smoke test fails. The previous colour stays running for
24 hours.

**Gate 7:** real login, file upload, PDF generation and a Realtime session,
verified by hand.

---

### Phase 8 — Recovery rehearsal (mandatory before cutover)

```bash
tofu apply -var-file=restore-test.tfvars     # throwaway instance
COMPOSE_PROJECT_NAME=vetsync-restoretest ./restore.sh --latest
./smoke-test.sh
```

Time it. That number **is** your real RTO.

**Gate 8:** restore verified on a different instance, duration recorded, and a
frontend rollback executed at least once.

---

### Phase 9 — Cutover

1. Announced maintenance window.
2. Final verified backup.
3. DNS TTL already at 300 (set when the records were created).
4. `smoke-test.sh`.
5. Monitor for 48 hours.
6. Raise TTL to 14400 after a stable week.

---

### Phase 10 — Clinical diagnosis service (`vetsync-diagnostic` + `ollaya`) · ✅ executed 2026-09-29

Unlike phases 1-9, these two services **don't live in Docker or in this
repo**: they're Rust binaries deployed as `systemd` units on the same host,
outside `compose.prod.yml`. Documented here because they share the same VPS
and the same secrets flow (`/etc/vetsync/prd.env`), but **not under IaC or
versioned as an artifact** yet — see the pending item below.

**What they solve:** the `diagnose-medical-report` edge function (in
`supabase/functions/` of the `vetsync-vet` repo) calls an internal service
that scores the clinical severity of echocardiogram reports via a local
LLM. Chain: edge function → `vetsync-diagnostic` (Rust, typed proxy) →
`ollaya` (local inference engine, CPU-only) → `laya:latest` model.

```
functions (container, "core" network)
  │  VETSYNC_DIAGNOSTIC_URL=http://172.30.0.1:8090
  ▼
vetsync-diagnostic.service (systemd, host, 0.0.0.0:8090)
  │  MELICLAW_SYSTEMONE_SYSTEMONE_URL=http://127.0.0.1:11435/v1/systemone
  ▼
ollaya.service (systemd, host, 127.0.0.1:11435)
  │  laya:latest model (router → laya:en / laya:multilingual, ONNX, ~1.5 GB)
  ▼
CPU (no GPU — built without the mlx/coreml/cuda features)
```

**Why `systemd`, not a container:** `ollaya` is the same engine used in
development (`meliclaw-decision-core/ollaya`), with official support for
`aarch64-unknown-linux-gnu` via the ONNX Runtime CPU provider — no need for
its own Docker image, just a cross-compile.

**Build (on the Mac, never on the VPS):**

```bash
cargo install cross --git https://github.com/cross-rs/cross

# ollaya — without mlx/coreml/cuda, falls back to the CPU provider
cd meliclaw-decision-core/meliclaw-systemone-core-2
cross build --release --target aarch64-unknown-linux-gnu --bin ollaya -p ollaya

# vetsync-diagnostic — reqwest with rustls (see PR agentiza-ai/agentic-core#2;
# native-tls/openssl-sys won't cross-compile without ARM64 libssl-dev
# inside the `cross` container)
cd meliclaw-decision-core/vetsync-diagnostic
cross build --release --target aarch64-unknown-linux-gnu --bin server
```

**Deploy (binary + unit only, never the Rust toolchain on the VPS):**

```bash
scp -i <key> target/aarch64-unknown-linux-gnu/release/ollaya \
  root@vetsync-vet-br-prd:/tmp/ollaya
ssh -i <key> root@vetsync-vet-br-prd '
  useradd --system --home-dir /usr/share/ollaya --create-home \
    --shell /usr/sbin/nologin ollaya
  install -m 755 /tmp/ollaya /usr/local/bin/ollaya
  # official unit: meliclaw-systemone-core-2/packaging/ollaya.service
  systemctl enable --now ollaya
  sudo -u ollaya HOME=/usr/share/ollaya OLLAYA_HOST=127.0.0.1:11435 \
    /usr/local/bin/ollaya pull laya:latest
'
```

`vetsync-diagnostic` follows the same pattern (its own `useradd`, its own
unit, `Requires=ollaya.service`); see the real unit at
`/etc/systemd/system/vetsync-diagnostic.service` on the VPS — not versioned
in any repo yet.

**Network:** neither port (`8090`, `11435`) is published in
`compose.prod.yml` or in Scaleway's security group — they're
`0.0.0.0:8090`/`127.0.0.1:11435` at the host level, reachable from Docker
containers only through the bridge network's gateway (`172.30.0.1` for the
`core` network), never from the Internet. Verified with `curl` against the
public IP from outside (timeout) before calling this step closed.

**Secret wiring** (same mechanism as `MAILTRAP_API_TOKEN`/`RESEND_API_KEY`,
not a new one):

1. `compose.prod.yml`, `functions.environment` block: add
   `VETSYNC_DIAGNOSTIC_URL: ${VETSYNC_DIAGNOSTIC_URL:-}`.
2. `/etc/vetsync/prd.env`: `VETSYNC_DIAGNOSTIC_URL=http://172.30.0.1:8090`.
3. `cd /opt/vetsync/current && set -a; . /etc/vetsync/prd.env; set +a && docker compose -f compose.prod.yml up -d --no-deps functions`.

**Gate 10:**
```bash
# inside the VPS — full chain, no external network
curl -s http://127.0.0.1:8090/v1/diagnostico/eco -X POST \
  -H 'Content-Type: application/json' \
  -d '{"numero_relatorio":"TEST","laudo_texto":"..."}'
# {"status":"ok","data":{...}}

# from outside — should get 401 (function loaded, auth gate stopped it)
curl -s -o /dev/null -w '%{http_code}\n' \
  https://api.vetsync.com.br/functions/v1/diagnose-medical-report -X POST
```

**Pending, not blocking for the current state but it is for reproducibility:**

- Binaries were built and copied by hand; no CI pipeline rebuilds or
  versions them. A from-scratch VPS reprovision (Phase 3) does **not**
  reinstall `ollaya`/`vetsync-diagnostic` — the two units
  (`ollaya.service`, `vetsync-diagnostic.service`) and the `cross build`
  step still need to land in `host-bootstrap.sh` or a dedicated script.
- This repo's (`vetsync-db-core`) `compose.prod.yml` was out of sync with
  what actually runs on the VPS (missing `RESEND_API_KEY`,
  `MAILTRAP_API_TOKEN`, the `meliclaw-dss` network, and now
  `VETSYNC_DIAGNOSTIC_URL`) — sync before the next Phase 6.

---

## 4. Resource budget (16 GB / 4 vCPU)

| Service | `mem_limit` | Note |
|---|---:|---|
| db | 7 GB | `shared_buffers=4GB`, `effective_cache_size=10GB` |
| realtime | 1 GB | grows with WebSocket connections |
| functions | 1 GB | ~85 edge functions |
| imgproxy | 1 GB | spikes per transformation |
| studio | 1 GB | candidate to stop unless needed |
| kong · rest · storage · supavisor | 512 MB each | |
| auth · meta · caddy | 256 MB each | |
| web-blue/green | 128 MB each | |

Total ceiling **13.75 GB** plus 8 GB swap. Without `mem_limit`, an `imgproxy`
spike kills Postgres through the OOM killer.

---

## 5. Backups

| Layer | Frequency | Destination |
|---|---|---|
| `pg_dump -Fc`, age-encrypted | daily | versioned Object Storage |
| Storage objects | daily, same archive | same |
| WAL archive (`archive_mode=on`) | continuous | pruned to 2 days after upload |
| Volume snapshot | before major changes | Scaleway |
| **Restore test** | **monthly, timed** | throwaway instance |

The age private key lives **off** the VPS. A root compromise must not also
hand over the backups.

Postgres rows and Storage objects are backed up **together**. Restoring the
database alone leaves every report, DICOM image and surgical consent form as a
dangling reference.

Targets: RPO 24 h → 15 min with WAL. RTO 4 h.

---

## 6. Blue/green and canary limits

| Component | Strategy | Why |
|---|---|---|
| React | **Blue/green** | Stateless, no schema, no shared volume |
| Kong, Auth, REST, Storage, Realtime, meta, imgproxy, functions | **Recreate with digest rollback** | One database; Kong is the single ingress and routes by container DNS name; GoTrue and Storage migrate schema at startup; Storage writes the same tree and `storage.objects` |
| Postgres | **Expand/contract plus a window** | Reverting an image does not revert data |
| Canary | **No** | One VPS does not isolate failures; the JWT lives in `localStorage` so a reload jumps versions; the shared schema cancels the benefit; without observability there is no signal to act on |

Progression: recreate + rollback → frontend blue/green → observability →
second node with a replica → canary.

---

## 7. Acceptance criteria

- [ ] `nmap -Pn -p- 51.15.108.6` returns exactly `22`, `80`, `443`
- [ ] `tofu apply` rebuilds the infrastructure from nothing
- [ ] Every image referenced by `sha256:`
- [ ] Frontend rollback in under 60 s with no rebuild
- [ ] A backup restored on another instance, duration measured
- [ ] No secrets in git or in the Tofu state
- [ ] Alerts for disk, RAM, CPU, availability and backup failure
- [ ] Studio unreachable from the internet
- [ ] `smoke-test.sh` green, including the RLS check
- [ ] Rollback executed at least once in rehearsal

---

## 8. DBA access

No published database ports. Reach the pooler over Tailscale, or run `psql`
inside the host:

```bash
ssh deploy@vetsync-vet-br-prd \
  'docker compose -f /opt/vetsync/current/compose.prod.yml exec db psql -U postgres'
```

For DBeaver the tenant-qualified user is `postgres.vetsync-db-core-prd`.
Do not combine it with `options=reference=...` — that is a different routing
mechanism.
