# VetSync PRD — Despliegue en Scaleway

Plan de implementación por fases, con un gate de validación explícito en cada
paso. Ninguna fase avanza mientras su gate esté en rojo.

> ⚠️ **Aislamiento multi-tenant, parcialmente resuelto:**
> [auditoría](../specs/VetSync%20RLS%20Audit%20and%20Remediation%20Plan.md) ·
> [registro de cambios en la BD](../specs/VetSync%20DB%20Change%20Log%20—%20RLS%20Remediation.md).
> Acceso anónimo cerrado, 114 de 211 tablas aisladas. Faltan 97; el cutover sigue bloqueado.

> Runbook operativo (todo lo ejecutado, verificación y rollback):
> [`../specs/VetSync PRD Deployment Runbook.md`](../specs/VetSync%20PRD%20Deployment%20Runbook.md)

> Versión en inglés: [`README.en.md`](README.en.md). Ambos describen el mismo
> plan; mantenerlos sincronizados cuando cambie cualquiera de los dos.

**Destino:** Scaleway `BASIC2-A4C-16G` (ARM64 / Ampere Neoverse-N1), Ubuntu
24.04.4 LTS, AMS1 · `51.15.108.6` · tailnet `vetsync-vet-br-prd.tail48dc0d.ts.net`

---

## 0. Índice de artefactos

| Archivo | Rol |
|---|---|
| [`compose.prod.yml`](compose.prod.yml) | Stack productivo standalone. Sustituye al override de OrbStack |
| [`caddy/Caddyfile`](caddy/Caddyfile) | TLS, routing por Host, allowlist de rutas de API |
| [`caddy/snippets/web-upstream.caddy`](caddy/snippets/web-upstream.caddy) | Interruptor blue/green del frontend |
| [`api/kong.yml`](api/kong.yml) | Configuración declarativa de Kong para producción |
| [`api/kong-entrypoint.sh`](api/kong-entrypoint.sh) | Sustitución de env y traducción de claves opacas |
| [`pooler/pooler.exs`](pooler/pooler.exs) | Aprovisionamiento del tenant de Supavisor |
| [`db/`](db/) | SQL de inicialización de Postgres (roles, JWT, realtime, pooler, webhooks) |
| [`cloud-init/vetsync-prd.yaml`](cloud-init/vetsync-prd.yaml) | Bootstrap endurecido del host |
| [`terraform/`](terraform/) | OpenTofu: instancia, IP, security group, bucket, IAM |
| [`env/prd.env.example`](env/prd.env.example) | Plantilla de entorno productivo |
| [`scripts/host-bootstrap.sh`](scripts/host-bootstrap.sh) | Aprovisionamiento de Fase 3, paso a paso y auditable |
| [`scripts/preflight.sh`](scripts/preflight.sh) | Verificación del host antes de desplegar |
| [`scripts/deploy-stack.sh`](scripts/deploy-stack.sh) | Recreate controlado de los servicios Supabase |
| [`scripts/deploy-web.sh`](scripts/deploy-web.sh) | Release blue/green del frontend |
| [`scripts/rollback-web.sh`](scripts/rollback-web.sh) | Vuelta al color anterior |
| [`scripts/backup.sh`](scripts/backup.sh) | Backup cifrado off-box (base de datos + objetos) |
| [`scripts/restore.sh`](scripts/restore.sh) | Restore con resincronización obligatoria de roles |
| [`scripts/smoke-test.sh`](scripts/smoke-test.sh) | Verificación post-despliegue |

En `vetsync-vet`: `Dockerfile`, `docker/nginx.conf`,
`docker/docker-entrypoint.d/10-runtime-config.sh`, `src/lib/runtimeConfig.ts`,
`.github/workflows/web-build-deploy.yml`.

---

## 1. Decisiones ya tomadas

| Tema | Decisión |
|---|---|
| Estrategia | Blue/green solo para el frontend · recreate controlado en Supabase · expand/contract en Postgres · **sin canary** |
| Entrega | Mac → git → CI (ARM64) → registry → el VPS hace pull por digest |
| IaC | OpenTofu con el provider de Scaleway |
| Objetivo | Superficie pública mínima, releases inmutables, datos separados del código |
| Acceso | SSH sobre Tailscale |
| Región | **AMS1**, confirmada el 2026-08-09 |
| Almacenamiento | **Volumen único** aceptado, con monitorización moderada (decisión 2026-08-09) |

### Verificado, no supuesto

Cada punto se comprobó contra la cosa real, no se dedujo:

- `BASIC2-A4C-16G` es ARM64 (Ampere). El kernel del host reporta `aarch64`
  y la CPU es `Neoverse-N1`.
- Las **12 imágenes** (11 de Supabase más Caddy) publican manifest `arm64`.
  Sin bloqueo de arquitectura.
- Todas están **pinneadas por digest** en `compose.prod.yml`. Los tags son
  documentación, y `deploy-stack.sh` rechaza cualquier tag flotante.
- `kong.yml` pasa `kong config parse` con el binario real de Kong 3.9.1
  (21 servicios). Un anchor YAML de nivel superior fue **rechazado** por Kong
  y hubo que moverlo a la primera entrada de plugin.
- Postgres dentro de `supabase/postgres:17.6` corre como **uid 100, gid 101**,
  no como el 105/106 que se asumió al principio. Un owner incorrecto hace que
  Postgres falle sobre PGDATA con `permission denied`.
- `docker compose config` renderiza exactamente cuatro puertos publicados:
  Caddy en `0.0.0.0:80`, `:443/tcp`, `:443/udp`, y Kong en `127.0.0.1:8000`.
  Postgres y Supavisor no publican nada.

---

## 2. Arquitectura destino

```
Internet
  │  Security group: stateful, inbound DROP
  │  443/tcp · 443/udp · 80/tcp · 41641/udp · 22 restringido
  ▼
Caddy ── único proceso en la interfaz pública
  ├── app.vetsync.com.br    ─┐
  ├── admin.vetsync.com.br  ─┴─→ web-blue | web-green   (red edge)
  └── api.vetsync.com.br     ──→ kong:8000  [ALLOWLIST DE RUTAS]
                                   │
Tailscale ── Studio ───────────────┤ 127.0.0.1:8000
                                   ▼  (red core)
        auth · rest · realtime · storage · imgproxy · meta · functions · studio
                                   ▼
                            supavisor → db
                                   ▼
                              /srv/vetsync
```

Layout en disco — código y datos estrictamente separados, aunque compartan un
solo volumen:

```
/opt/vetsync/releases/<sha>/   código y configuración de la release
/opt/vetsync/current ->        symlink a la release activa
/srv/vetsync/postgres/         PGDATA (uid 100, modo 700)
/srv/vetsync/storage/          objetos
/srv/vetsync/functions/<sha>/  edge functions versionadas
/srv/vetsync/caddy/            estado de Caddy y snippet blue/green
/srv/vetsync/manifests/        manifiestos compose anteriores, para rollback
/etc/vetsync/prd.env           secretos, 0600 root:root
/var/backups/vetsync/          staging previo al upload
/var/log/vetsync/              log de auditoría del aprovisionamiento
```

---

## 3. Fases

### Fase 0 — Decisiones bloqueantes · ✅ cerrada

| Ítem | Estado |
|---|---|
| Región | ✅ **AMS1** |
| Documentación LGPD | ⚠️ **Abierto.** Datos clínicos brasileños alojados en Países Bajos. LGPD Art. 33 exige base jurídica documentada y salvaguardas, más contrato de operador con Scaleway. Es un documento, no código, y debe existir antes de mover datos reales de pacientes. Contar con ~200 ms de RTT desde Brasil (126 ms medidos por el tailnet) |
| Apex y MX | ✅ Siguen en HostGator (`69.6.215.134`). Sin tocar |
| `console.vetsync.com.br` | ✅ Sin registro A público. Studio solo por Tailscale |
| Volumen de datos | ✅ Volumen único aceptado, con el disk guard de la Fase 3 |

---

### Fase 1 — Preparar los repositorios · ✅ ejecutada 2026-08-09

```bash
cd /Volumes/Backup/Projects/src/heyzify/data-platform/data-core/wapnet/vetsync-db-core
chmod +x deploy/scripts/*.sh
```

Secretos excluidos de git (ya aplicado a `.gitignore`):

```
deploy/terraform/*.tfvars
deploy/terraform/backend.hcl
deploy/terraform/.terraform/
deploy/terraform/*.tfstate*
deploy/env/prd.env
```

Cambios aplicados en `vetsync-vet`. Resultaron ser **19 archivos**, no 4: la
inspección encontró 11 archivos más leyendo `import.meta.env.VITE_SUPABASE_*`
directamente, varios con fallback al proyecto Supabase Cloud legacy. El detalle
y la verificación están en el [runbook](../specs/VetSync%20PRD%20Deployment%20Runbook.md#41-fase-1--aplicación-vetsync-vet).

1. **`vite.config.ts:17`** — `mcpPlugin()` entra hoy al bundle de producción
   porque no está condicionado al modo:
   ```diff
   -    mcpPlugin(),
   +    mode === "development" && mcpPlugin(),
   ```
2. **`index.html`** — cargar la config de runtime antes del bundle de módulos.
   Debe ser un `<script>` síncrono; un `fetch()` competiría con la evaluación
   de módulos:
   ```html
   <script src="/config.js"></script>
   <script type="module" src="/src/main.tsx"></script>
   ```
3. **`src/integrations/supabase/client.ts`** — leer de `runtimeConfig`:
   ```ts
   import { runtimeConfig } from '@/lib/runtimeConfig';
   export const supabase = createClient<Database>(
     runtimeConfig.SUPABASE_URL,
     runtimeConfig.SUPABASE_PUBLISHABLE_KEY,
     { auth: { storage: localStorage, persistSession: true, autoRefreshToken: true } }
   );
   ```
   > Ese archivo está marcado como "automatically generated". Confirmar que
   > Lovable no lo regenere y pierda el cambio; si lo hace, mover el cliente
   > a otro módulo.
4. **PWA** — decidir. `VitePWA({ selfDestroying: true })` genera hoy un service
   worker cuyo único trabajo es desregistrarse, así que el PWA no funciona.
   O se activa —y entonces el SW condiciona el blue/green— o se elimina la
   dependencia.

**Gate 1:** `npx tsc --noEmit && npm run lint && npx vitest run` en verde, y
`docker compose -f deploy/compose.prod.yml config -q` limpio.

---

### Fase 2 — Infraestructura (OpenTofu) · 🔄 import hecho, `apply` pendiente

```bash
cd deploy/terraform
cp prd.tfvars.example prd.tfvars      # project_id, admin_ssh_cidrs
cp backend.hcl.example backend.hcl    # bucket del state

export SCW_ACCESS_KEY=... SCW_SECRET_KEY=... SCW_DEFAULT_ORGANIZATION_ID=...

tofu init -backend-config=backend.hcl
tofu plan  -var-file=prd.tfvars
tofu apply -var-file=prd.tfvars
```

> La instancia actual se creó a mano. Para ponerla bajo IaC sin recrearla,
> importar **antes** de cualquier apply, o Tofu construirá una segunda:
> ```bash
> tofu import -var-file=prd.tfvars scaleway_instance_server.main nl-ams-1/5a502bd5-fa8d-49fa-8544-52959aad...
> ```

> Como la decisión de volumen único se mantiene, hay que quitar
> `scaleway_block_volume.data` de `main.tf` o dejarlo sin adjuntar. No dejes
> que el plan cree en silencio un volumen que nadie monta.

**Gate 2:**
```bash
tofu output public_ipv4                # 51.15.108.6
nmap -Pn -p- 51.15.108.6 | grep open   # exactamente 22, 80, 443
```
El security group que Scaleway crea automáticamente es **stateless**;
confirmar que la instancia usa el dedicado stateful, no el de por defecto.

---

### Fase 3 — Aprovisionamiento del host · ✅ ejecutada 2026-08-09

Se ejecuta en pasos discretos, idempotentes y auditados. Cada ejecución añade
a `/var/log/vetsync/provisioning.log` el timestamp UTC, el operador, la
dirección SSH de origen, el comando exacto y su salida. Todo archivo que se
sobrescriba se copia antes a `<archivo>.bak.<timestamp>`.

```bash
./host-bootstrap.sh --list
./host-bootstrap.sh --step 1 --dry-run   # imprime, no cambia nada
./host-bootstrap.sh --step 1             # ejecuta
```

| Paso | Qué hace | Estado |
|---|---|---|
| 1 | `daemon.json`: rotación de logs, `userland-proxy: false`, pool `172.30.0.0/16`; valida el JSON y reinicia Docker | ✅ |
| 2 | Swap de 8 GB, `vm.swappiness=10`, límites de sockets y descriptores | ✅ |
| 3 | Layout de directorios, `/etc/vetsync` en 700, PGDATA con owner uid 100 | ✅ |
| 4 | Usuario `deploy`, clave ed25519, sudoers acotado, password bloqueado | ✅ |
| 5 | Timer de disk guard cada 15 min (aviso 75 %, crítico 85 %) | ✅ |
| 6 | `fail2ban` + `PermitRootLogin no` | ⏸ pendiente de confirmación |

Dos decisiones de diseño que conviene conservar:

- **`vm.overcommit_memory` se queda en `0`.** El modo estricto (`2`) es lo
  correcto en un host dedicado a Postgres, pero aquí conviven BEAM (Realtime,
  Supavisor) y Deno, que reservan regiones virtuales grandes. Un `CommitLimit`
  estricto se manifiesta como fallos de asignación opacos. El techo real es
  `mem_limit` más swap.
- **`default-address-pools` está fijado.** Sin eso Docker elige `172.17+` de
  forma dinámica y puede colisionar con rangos de VPN o del cliente. El
  `ignoreip` de fail2ban y las reglas nftables asumen `172.30.0.0/16`.

El paso 6 va deliberadamente al final, y el script se niega a ejecutarlo si no
existe el usuario `deploy`, si no tiene `authorized_keys` o si Tailscale no
está conectado — de lo contrario la única vía de regreso es la consola serial
de Scaleway.

**Gate 3:** `preflight.sh` reporta 0 fallos.

---

### Fase 4 — Artefactos versionados

Las edge functions se entregan como tarball, no como symlink a otro
repositorio. El `VETSYNC_PRD_FUNCTIONS_DIR` local sube cuatro niveles hasta
`vetsync-os`, una ruta que en el VPS no existe.

```bash
SHA=$(git -C ../../wapnet/vetsync-os/vetsync-vet rev-parse --short HEAD)
tar -C ../../wapnet/vetsync-os/vetsync-vet/supabase -czf functions-$SHA.tar.gz functions
scp functions-$SHA.tar.gz deploy@vetsync-vet-br-prd:/tmp/

ssh deploy@vetsync-vet-br-prd bash -s <<EOF
  mkdir -p /srv/vetsync/functions/$SHA
  tar -C /srv/vetsync/functions/$SHA --strip-components=1 -xzf /tmp/functions-$SHA.tar.gz
  ln -sfn /srv/vetsync/functions/$SHA /srv/vetsync/functions/current
EOF
```

Release del stack — el árbol `deploy/` es autocontenido, así que es un rsync:

```bash
SHA=$(git rev-parse --short HEAD)
rsync -a --delete deploy/ deploy@vetsync-vet-br-prd:/opt/vetsync/releases/$SHA/
ssh deploy@vetsync-vet-br-prd "ln -sfn /opt/vetsync/releases/$SHA /opt/vetsync/current"
```

**Gate 4:** `preflight.sh` confirma `main/index.ts` y más de diez directorios
de funciones.

---

### Fase 5 — Base de datos · 🚫 bloqueada por la remediación RLS

Levantar solo `db` y restaurar de forma **lógica**. No copiar `PGDATA` a nivel
de filesystem: es frágil por versión, locale/ICU, checksums y estado del WAL,
y ya existe un flujo correcto con `pg_dump -Fc`.

```bash
set -a && . /etc/vetsync/prd.env && set +a
docker compose -f /opt/vetsync/current/compose.prod.yml up -d db
docker compose -f /opt/vetsync/current/compose.prod.yml exec db pg_isready -U postgres

export VETSYNC_RESTORE_CONFIRM=yes VETSYNC_RESTORE_PRODUCTION=yes
/opt/vetsync/current/scripts/restore.sh --file <backup>.tar.age
```

`restore.sh` habilita `pg_trgm` (los índices GIN de trigramas del backup lo
exigen) y **resincroniza los roles de servicio** con el entorno actual al
terminar. Sin ese paso, Auth, PostgREST, Storage y Supavisor fallan con
SQLSTATE `28P01` contra una base de datos que por lo demás está sana.

> **Antes de la Fase 5.** La remediación RLS se aplicó al stack local **sin
> migraciones**. Si se restaura el dump tal cual en el VPS, la base nace con
> RLS solo donde el dump la traiga. Hay que convertir `.artifacts/step-b*.sql`
> en migraciones versionadas y aplicarlas tras el restore, o el gate de abajo
> fallará.

**Gate 5:**
```sql
-- se esperan ~158
select count(*) from information_schema.tables where table_schema='public';

-- DEBE ser 0: una tabla en public sin RLS expone datos entre organizaciones
select count(*) from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;
```

---

### Fase 6 — Stack Supabase

```bash
/opt/vetsync/current/scripts/deploy-stack.sh
```

El script toma un backup primero (GoTrue y Storage migran esquema al
arrancar), guarda el manifiesto anterior para rollback, rechaza cualquier
imagen sin digest, recrea, espera healthchecks y ejecuta el smoke test.

**Gate 6:** `smoke-test.sh` en verde, incluido el bloque *Studio isolation*.

---

### Fase 7 — Frontend

```bash
gh workflow run web-build-deploy.yml -f deploy=true
```

`deploy-web.sh` levanta el color candidato, lo sondea directamente **antes**
de mover tráfico, cambia el snippet de Caddy, recarga en caliente y revierte
automáticamente si el smoke test falla. El color anterior sigue corriendo 24 h.

**Gate 7:** login real, subida de archivo, generación de PDF y una sesión de
Realtime, verificados a mano.

---

### Fase 8 — Ensayo de recuperación (obligatorio antes del cutover)

```bash
tofu apply -var-file=restore-test.tfvars     # instancia efímera
COMPOSE_PROJECT_NAME=vetsync-restoretest ./restore.sh --latest
./smoke-test.sh
```

Cronometrarlo. Ese número **es** tu RTO real.

**Gate 8:** restore verificado en otra instancia, duración registrada, y un
rollback de frontend ejecutado al menos una vez.

---

### Fase 9 — Cutover

1. Ventana de mantenimiento anunciada.
2. Backup final verificado.
3. TTL de DNS ya en 300 (fijado al crear los registros).
4. `smoke-test.sh`.
5. Monitorizar 48 h.
6. Subir el TTL a 14400 tras una semana estable.

---

### Fase 10 — Servicio de diagnóstico clínico (`vetsync-diagnostic` + `ollaya`) · ✅ ejecutada 2026-09-29

A diferencia de las fases 1-9, estos dos servicios **no viven en Docker ni en
este repo**: son binarios Rust desplegados como `systemd` units en el mismo
host, al margen del stack de `compose.prod.yml`. Quedan documentados aquí
porque comparten la misma VPS y el mismo flujo de secretos (`/etc/vetsync/prd.env`),
pero **no están bajo IaC ni versionados como artefacto** todavía — ver
pendiente al final.

**Qué resuelven:** la función `diagnose-medical-report` (edge function, en
`supabase/functions/` del repo `vetsync-vet`) llama a un servicio interno que
evalúa la gravedad clínica de laudos de ecocardiograma vía un LLM local.
Cadena: edge function → `vetsync-diagnostic` (Rust, proxy tipado) →
`ollaya` (motor de inferencia local, CPU-only) → modelo `laya:latest`.

```
functions (container, red "core")
  │  VETSYNC_DIAGNOSTIC_URL=http://172.30.0.1:8090
  ▼
vetsync-diagnostic.service (systemd, host, 0.0.0.0:8090)
  │  MELICLAW_SYSTEMONE_SYSTEMONE_URL=http://127.0.0.1:11435/v1/systemone
  ▼
ollaya.service (systemd, host, 127.0.0.1:11435)
  │  modelo laya:latest (router → laya:en / laya:multilingual, ONNX, ~1.5 GB)
  ▼
CPU (sin GPU — build sin features mlx/coreml/cuda)
```

**Por qué `systemd`, no contenedor:** `ollaya` es el mismo motor usado en
desarrollo (`meliclaw-decision-core/ollaya`), con soporte oficial de
`aarch64-unknown-linux-gnu` vía CPU provider de ONNX Runtime — no requirió
imagen Docker propia, solo cross-compile.

**Build (en el Mac, nunca en el VPS):**

```bash
cargo install cross --git https://github.com/cross-rs/cross

# ollaya — sin mlx/coreml/cuda, cae al provider CPU
cd meliclaw-decision-core/meliclaw-systemone-core-2
cross build --release --target aarch64-unknown-linux-gnu --bin ollaya -p ollaya

# vetsync-diagnostic — reqwest con rustls (ver PR agentiza-ai/agentic-core#2;
# native-tls/openssl-sys no cross-compila sin libssl-dev ARM64 en el
# contenedor de `cross`)
cd meliclaw-decision-core/vetsync-diagnostic
cross build --release --target aarch64-unknown-linux-gnu --bin server
```

**Despliegue (binario + unit, nunca el toolchain Rust en el VPS):**

```bash
scp -i <key> target/aarch64-unknown-linux-gnu/release/ollaya \
  root@vetsync-vet-br-prd:/tmp/ollaya
ssh -i <key> root@vetsync-vet-br-prd '
  useradd --system --home-dir /usr/share/ollaya --create-home \
    --shell /usr/sbin/nologin ollaya
  install -m 755 /tmp/ollaya /usr/local/bin/ollaya
  # unit oficial: meliclaw-systemone-core-2/packaging/ollaya.service
  systemctl enable --now ollaya
  sudo -u ollaya HOME=/usr/share/ollaya OLLAYA_HOST=127.0.0.1:11435 \
    /usr/local/bin/ollaya pull laya:latest
'
```

`vetsync-diagnostic` sigue el mismo patrón (`useradd` propio, unit propia,
`Requires=ollaya.service`); ver la unit real en
`/etc/systemd/system/vetsync-diagnostic.service` en el VPS — no versionada
en ningún repo todavía.

**Red:** ninguno de los dos puertos (`8090`, `11435`) se publica en
`compose.prod.yml` ni en el security group de Scaleway — son
`0.0.0.0:8090`/`127.0.0.1:11435` a nivel de host, alcanzables desde los
contenedores de Docker solo por el gateway de la red bridge
(`172.30.0.1` para la red `core`), nunca desde Internet. Verificado con
`curl` contra la IP pública desde fuera (timeout) antes de dar el paso por
cerrado.

**Wiring del secreto** (mismo mecanismo que `MAILTRAP_API_TOKEN`/
`RESEND_API_KEY`, no uno nuevo):

1. `compose.prod.yml`, bloque `functions.environment`: añadir
   `VETSYNC_DIAGNOSTIC_URL: ${VETSYNC_DIAGNOSTIC_URL:-}`.
2. `/etc/vetsync/prd.env`: `VETSYNC_DIAGNOSTIC_URL=http://172.30.0.1:8090`.
3. `cd /opt/vetsync/current && set -a; . /etc/vetsync/prd.env; set +a && docker compose -f compose.prod.yml up -d --no-deps functions`.

**Gate 10:**
```bash
# dentro del VPS — cadena completa, sin red externa
curl -s http://127.0.0.1:8090/v1/diagnostico/eco -X POST \
  -H 'Content-Type: application/json' \
  -d '{"numero_relatorio":"TEST","laudo_texto":"..."}'
# {"status":"ok","data":{...}}

# desde fuera — debe dar 401 (function cargó, auth gate la detuvo)
curl -s -o /dev/null -w '%{http_code}\n' \
  https://api.vetsync.com.br/functions/v1/diagnose-medical-report -X POST
```

**Pendiente, no bloqueante para el estado actual pero sí para reproducibilidad:**

- Los binarios se compilaron y copiaron a mano; no hay pipeline de CI que
  los reconstruya ni los versione. Un reinicio de VPS desde cero (Fase 3)
  **no** reinstala `ollaya`/`vetsync-diagnostic` — falta llevar las dos
  units (`ollaya.service`, `vetsync-diagnostic.service`) y el paso de
  `cross build` a `host-bootstrap.sh`/un script propio.
- `compose.prod.yml` de este repo (`vetsync-db-core`) estaba desactualizado
  respecto al que corre en el VPS (le faltaban `RESEND_API_KEY`,
  `MAILTRAP_API_TOKEN`, la red `meliclaw-dss` y ahora `VETSYNC_DIAGNOSTIC_URL`)
  — sincronizar antes de la próxima Fase 6.

---

## 4. Presupuesto de recursos (16 GB / 4 vCPU)

| Servicio | `mem_limit` | Nota |
|---|---:|---|
| db | 7 GB | `shared_buffers=4GB`, `effective_cache_size=10GB` |
| realtime | 1 GB | crece con las conexiones WebSocket |
| functions | 1 GB | ~85 edge functions |
| imgproxy | 1 GB | picos por transformación |
| studio | 1 GB | candidato a apagar salvo cuando se necesite |
| kong · rest · storage · supavisor | 512 MB c/u | |
| auth · meta · caddy | 256 MB c/u | |
| web-blue/green | 128 MB c/u | |

Techo total **13,75 GB** más 8 GB de swap. Sin `mem_limit`, un pico de
`imgproxy` mata Postgres por el OOM killer.

---

## 5. Backups

| Capa | Frecuencia | Destino |
|---|---|---|
| `pg_dump -Fc` cifrado con age | diario | Object Storage versionado |
| Objetos de Storage | diario, mismo archivo | ídem |
| WAL archive (`archive_mode=on`) | continuo | poda a 2 días tras subir |
| Snapshot de volumen | antes de cambios grandes | Scaleway |
| **Restore test** | **mensual, cronometrado** | instancia efímera |

La clave privada `age` vive **fuera** del VPS. Un compromiso de root no debe
entregar también los backups.

Las filas de Postgres y los objetos de Storage se respaldan **juntos**.
Restaurar solo la base deja cada laudo, imagen DICOM y consentimiento
quirúrgico como una referencia colgante.

Objetivos: RPO 24 h → 15 min con WAL. RTO 4 h.

---

## 6. Límites de blue/green y canary

| Componente | Estrategia | Por qué |
|---|---|---|
| React | **Blue/green** | Sin estado, sin esquema, sin volumen compartido |
| Kong, Auth, REST, Storage, Realtime, meta, imgproxy, functions | **Recreate con rollback por digest** | Una sola base de datos; Kong es el ingress único y rutea por nombre DNS de contenedor; GoTrue y Storage migran esquema al arrancar; Storage escribe el mismo árbol y `storage.objects` |
| Postgres | **Expand/contract más ventana** | Revertir una imagen no revierte los datos |
| Canary | **No** | Un solo VPS no aísla fallos; el JWT vive en `localStorage`, así que una recarga salta de versión; el esquema compartido anula el beneficio; sin observabilidad no hay señal sobre la que actuar |

Progresión: recreate + rollback → blue/green de frontend → observabilidad →
segundo nodo con réplica → canary.

---

## 7. Criterios de aceptación

- [ ] `nmap -Pn -p- 51.15.108.6` devuelve exactamente `22`, `80`, `443`
- [ ] `tofu apply` reconstruye la infraestructura desde cero
- [ ] Toda imagen referenciada por `sha256:`
- [ ] Rollback del frontend en menos de 60 s sin recompilar
- [ ] Un backup restaurado en otra instancia, con duración medida
- [ ] Sin secretos en git ni en el state de Tofu
- [ ] Alertas de disco, RAM, CPU, disponibilidad y fallo de backup
- [ ] Studio inalcanzable desde Internet
- [ ] `smoke-test.sh` en verde, incluida la comprobación de RLS
- [ ] Rollback ejecutado al menos una vez en ensayo

---

## 8. Acceso DBA

Sin puertos de base de datos publicados. Se llega al pooler por Tailscale, o
se ejecuta `psql` dentro del host:

```bash
ssh deploy@vetsync-vet-br-prd \
  'docker compose -f /opt/vetsync/current/compose.prod.yml exec db psql -U postgres'
```

Para DBeaver, el usuario con tenant es `postgres.vetsync-db-core-prd`.
No combinarlo con `options=reference=...` — es un mecanismo de routing distinto.
