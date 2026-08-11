# node-runtime-base

Imagen base de Node.js 24 hardenizada, para servicios de la plataforma.

`ghcr.io/mantoniocc/node-runtime-base`

---

## Contrato

Toda imagen publicada cumple y verifica automáticamente lo siguiente. Estas son promesas: romper cualquiera es un cambio **MAJOR**.

| Garantía | Valor |
|---|---|
| Usuario por defecto | `node` — UID/GID **1000**, sin privilegios |
| Runtime | Node.js **24.x** + npm |
| Distribución base | Debian **12 (bookworm)** slim |
| PID 1 | `tini` — propaga señales y reapea zombies |
| Certificados CA | Presentes (`ca-certificates`) |
| Directorio de trabajo | `/app`, propiedad de `node` |
| Caché de apt | Vacía |
| Herramientas de red | **Ausentes** — sin `curl` ni `wget` |
| `CMD` | **Ninguno** — lo define el consumidor |
| `NODE_ENV` | **No seteado** — no rompe multi-stage builds |

El contrato se verifica en cada build con [`scripts/verify-image.sh`](scripts/verify-image.sh). Si un check falla, la imagen no se publica.

---

## Uso

### Referencia recomendada

```dockerfile
# Producción: anclado por digest, inmutable
FROM ghcr.io/mantoniocc/node-runtime-base@sha256:050fbc5b...
```

### Tags disponibles

| Tag | Se mueve cuando | Para quién |
|---|---|---|
| `:1` | Sale cualquier `1.x.x` | Servicios que quieren parches automáticos |
| `:1.4` | Sale cualquier `1.4.x` | Conservador: acepta patches, no minors |
| `:1.4.0` | Nunca en la práctica | Casi producción |
| `:latest` | Sale cualquier estable | Exploración, pruebas rápidas |
| `@sha256:...` | **Nunca** | Producción seria |

Los cuatro primeros son punteros mutables al mismo digest. Solo la referencia por digest da garantía criptográfica de inmutabilidad.

También aparecen tags con el formato `sha256-<digest>`: **no son imágenes**, son las attestations almacenadas como referrers OCI. No los uses en un `FROM`.

### Plataformas

`linux/amd64` y `linux/arm64`.

### Pull anónimo

La imagen es pública: no hace falta autenticarse.

```bash
docker pull ghcr.io/mantoniocc/node-runtime-base:1
```

A diferencia del registry npm de GitHub Packages, GHCR permite pull anónimo de paquetes públicos, porque los contenedores se consumen desde kubelets y runtimes sin identidad de GitHub.

---

## Cómo consumir esta base

### Servicio simple

```dockerfile
FROM ghcr.io/mantoniocc/node-runtime-base:1

WORKDIR /app
COPY --chown=node:node package*.json ./
RUN npm ci --omit=dev
COPY --chown=node:node . .

CMD ["node", "src/server.js"]
```

No hace falta `USER node` ni `ENTRYPOINT`: la base ya los define, y `tini` envuelve automáticamente tu `CMD`.

### Servicio con dependencias nativas

Regla: **las dependencias de compilación van en la etapa de build; las de runtime, en la etapa final.**

```dockerfile
# ---------- BUILD ----------
FROM ghcr.io/mantoniocc/node-runtime-base:1 AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 make g++ libvips-dev \
    && rm -rf /var/lib/apt/lists/*
USER node
WORKDIR /app
COPY --chown=node:node package*.json ./
RUN npm ci
COPY --chown=node:node . .
RUN npm run build && npm prune --omit=dev

# ---------- RUNTIME ----------
FROM ghcr.io/mantoniocc/node-runtime-base:1
USER root
# libvips42 (biblioteca compartida), NO libvips-dev (headers).
# Sin esto, sharp falla al cargar en tiempo de ejecución.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libvips42 \
    && rm -rf /var/lib/apt/lists/*
USER node
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
CMD ["node", "dist/server.js"]
```

El `USER root` / `USER node` es fricción deliberada: te obliga a justificar los privilegios y hace que un revisor lo vea en el diff. **No olvides volver a `USER node`** — si no, tu servicio corre como root sobre una base hardenizada.

### Desarrollo

Usá la misma base. Cambia el envoltorio, no el runtime.

```dockerfile
FROM ghcr.io/mantoniocc/node-runtime-base:1 AS dev
WORKDIR /app
COPY --chown=node:node package*.json ./
RUN npm ci
COPY --chown=node:node . .
CMD ["node", "--watch", "src/server.js"]
```

```yaml
services:
  api:
    build: { context: ., target: dev }
    volumes:
      - .:/app
      - /app/node_modules
```

---

## Verificar procedencia

Cada versión lleva dos attestations firmadas con Sigstore: **provenance** (quién construyó la imagen) y **SBOM** (qué contiene).

```bash
# Provenance — es el default de gh attestation verify
gh attestation verify \
  oci://ghcr.io/mantoniocc/node-runtime-base:1.4.1 \
  --owner mantoniocc
```

```
✓ Verification succeeded!
  - Build repo:..... mantoniocc/node-runtime-base
  - Build workflow:. .github/workflows/release.yml@refs/tags/v1.4.1
```

```bash
# SBOM — hay que pedirlo explícitamente
gh attestation verify \
  oci://ghcr.io/mantoniocc/node-runtime-base:1.4.1 \
  --owner mantoniocc \
  --predicate-type https://spdx.dev/Document
```

> **Importante:** `gh attestation verify` sin `--predicate-type` valida **solo la provenance**. Una política de admisión que no especifique el tipo no está verificando el SBOM.

Las imágenes anteriores a `v1.3.0` no tienen attestations y fallarán la verificación.

---

## Troubleshooting en producción

La imagen no trae herramientas de diagnóstico: `curl` y `wget` son las herramientas de exfiltración y de descarga de segunda etapa de cualquier atacante con RCE. Su ausencia es parte del contrato.

### Kubernetes — contenedores efímeros

```bash
kubectl debug -it pod/mi-api \
  --image=nicolaka/netshoot \
  --target=mi-api \
  -- bash
```

Comparte los namespaces de red y proceso del target. El pod no se reinicia, así que no perdés el estado del incidente.

```bash
ps aux                          # procesos del servicio
ss -tlnp                        # puertos en escucha
curl -v localhost:3000/health
tcpdump -i any port 5432
ls /proc/1/root/app             # filesystem del target
```

Pod en CrashLoopBackOff:

```bash
kubectl debug pod/mi-api --copy-to=mi-api-debug --set-image='*=busybox' -- sleep 1d
```

### Docker / Swarm — namespaces compartidos

```bash
CID=$(docker ps --filter "name=mi-servicio" -q | head -1)

docker run -it --rm \
  --network="container:$CID" \
  --pid="container:$CID" \
  --cap-add=SYS_PTRACE \
  nicolaka/netshoot
```

### Sin herramientas externas

Node cubre casi todo lo necesario para diagnosticar un servicio Node:

```bash
# En lugar de curl
node -e "fetch('http://localhost:3000/health').then(r=>r.text()).then(console.log)"

# En lugar de dig
node -e "require('dns').promises.resolve4('postgres.svc').then(console.log)"

# ¿El puerto está abierto?
node -e "require('net').connect(5432,'db').on('connect',()=>console.log('OK')).on('error',e=>console.log(e.code))"

# En lugar de ps
cat /proc/1/comm
ls /proc/[0-9]*/comm

# Variables de entorno de PID 1
cat /proc/1/environ | tr '\0' '\n'
```

---

## Mantenimiento

El `FROM` está anclado por digest al **índice multi-arquitectura** de `node:24-bookworm-slim`. El tag es explícito a propósito: define la vía de actualización de Dependabot y evita que una migración de distro llegue disfrazada de parche.

Dependabot abre un PR semanal cuando el upstream publica un digest nuevo. El CI valida el contrato antes del merge, incluido el check de `VERSION_CODENAME=bookworm`.

Ver [`docs/RUNBOOK.md`](docs/RUNBOOK.md) para publicar versiones y [`docs/MANIFESTS.md`](docs/MANIFESTS.md) para entender la estructura OCI.

---

## Licencia

MIT