# Manifests, índices y digests

Documento de referencia sobre la estructura interna de una imagen OCI. Escrito porque durante la construcción de este proyecto **la misma confusión causó tres problemas distintos**, y entender el modelo los resuelve todos.

---

## El problema en una frase

Una "imagen de contenedor" no es un objeto. Es un **árbol de objetos**, y cada herramienta lee un nivel distinto del árbol.

Cuando algo "no aparece", "no se puede cargar" o "no se verifica" en una imagen multi-arquitectura, la primera pregunta siempre es: **¿en qué nivel lo estoy buscando?**

---

## El árbol

```
  TAG                    :1.4.1                ← puntero MUTABLE
   │                                             (no es parte del árbol,
   ▼                                              apunta a él)
  ÍNDICE                 sha256:050fbc5b...    ← OCI image index
  (manifest list)                                 · annotations
   │                                              · lista de manifests
   │
   ├── linux/amd64  ───► sha256:aaa...  MANIFEST
   │                          │
   │                          ├──► CONFIG  sha256:ccc...
   │                          │     · labels        ← LABEL del Dockerfile
   │                          │     · env, user, entrypoint, cmd
   │                          │
   │                          └──► LAYERS
   │                                ├── sha256:ddd...  (base del SO)
   │                                ├── sha256:eee...  (apt install)
   │                                └── sha256:fff...  (mkdir, chown)
   │
   ├── linux/arm64  ───► sha256:bbb...  MANIFEST
   │                          └──► (su propio config y layers)
   │
   ├── unknown/unknown ─► attestation de amd64
   └── unknown/unknown ─► attestation de arm64
```

**Todo objeto se identifica por el SHA-256 de sus propios bytes.** No hay metadata mágica: el digest *es* el hash del contenido.

Comprobalo:

```bash
docker buildx imagetools inspect node:24-bookworm-slim --raw | shasum -a 256
docker buildx imagetools inspect node:24-bookworm-slim | awk '/^Digest:/{print $2; exit}'
```

Los dos valores coinciden. Por eso el digest es inmutable **por construcción**, no por política del registry: cambiar un byte produce otro digest, que es otro objeto.

---

## Los tres problemas que causa confundir niveles

### 1. `load: true` falla con múltiples plataformas

```
ERROR: docker exporter does not currently support exporting manifest lists
```

**Causa:** el daemon de Docker almacena **manifests** (una arquitectura). Un índice no es cargable — no hay forma de que `docker images` liste "una imagen de dos arquitecturas".

**Consecuencia práctica:** no podés ejecutar ni verificar una imagen multi-arch localmente. De ahí el patrón de dos builds del `release.yml`:

```
Build 1: solo amd64, load: true   →  verificable
        │  cache gha (mode=max)
        ▼
Build 2: amd64 + arm64, push: true
        └─ amd64 sale de cache
        └─ arm64 se construye y se publica SIN verificar
```

**Lo que sostiene la garantía no es el Dockerfile: es la cache.** Sin `cache-to: type=gha,mode=max`, ambos builds ejecutarían `apt-get install` por separado y podrían diferir.

### 2. "No description provided" en la UI de GHCR

**Causa:** los `LABEL` del Dockerfile viven en el **config de cada manifest de plataforma**. La página del package resuelve el **índice**, que es un nivel más arriba.

| | Label | Annotation |
|---|---|---|
| Dónde vive | Config del manifest | Índice |
| Quién la pone | `LABEL` en el Dockerfile | `annotations` en el push |
| La lee la UI de GHCR | ✗ | ✅ |
| La lee `docker inspect` | ✅ | ✗ |

**Solución:** declarar la descripción en ambos lugares. No es redundancia por error de diseño propio — son audiencias distintas leyendo niveles distintos.

```yaml
- uses: docker/metadata-action@v6
  with:
    labels: |
      org.opencontainers.image.description=...
    annotations: |
      org.opencontainers.image.description=...
```

Verificar cada nivel por separado:

```bash
# Nivel índice
docker buildx imagetools inspect IMAGEN --raw \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('annotations'))"

# Nivel config de plataforma
docker buildx imagetools inspect IMAGEN --format '{{json .Image.Config.Labels}}'
```

### 3. Entradas `unknown/unknown`

**No son plataformas: son attestations.** BuildKit las genera por defecto y las guarda dentro del mismo índice.

```json
{
  "platform": { "os": "unknown", "architecture": "unknown" },
  "annotations": {
    "vnd.docker.reference.type": "attestation-manifest",
    "vnd.docker.reference.digest": "sha256:<el manifest que atestigua>"
  }
}
```

**Por qué `unknown/unknown`:** es un hack de compatibilidad. Un cliente viejo que resuelve un índice busca una entrada que coincida con su plataforma; `unknown/unknown` nunca coincide con nada, así que se ignora silenciosamente. Eso permitió meter attestations en el formato sin romper clientes existentes.

Hay **una por arquitectura real**: 2 plataformas → 4 entradas en total.

---

## Contar objetos: por qué GHCR muestra "5 versiones" para una imagen

```
1 índice (con los tags)      ← el que ves con tags
2 manifests de plataforma    ← sin tags
2 attestations de BuildKit   ← sin tags
─────────────────────────
5 "versiones" en la API
```

Y si usás `push-to-registry: true` para las artifact attestations de GitHub, aparecen además tags con el formato `sha256-<digest>`. GHCR no implementa la API de referrers de OCI de forma nativa, así que se usa ese esquema de fallback: la attestation se sube como una imagen normal con ese tag.

**Consecuencia operativa crítica:** un workflow de limpieza que borre por antigüedad puede eliminar las attestations sin darse cuenta. El `ignore-versions` debe protegerlas:

```yaml
ignore-versions: '^(latest|\d+|\d+\.\d+|\d+\.\d+\.\d+|sha256-.*)$'
```

---

## Dos sistemas de procedencia coexistiendo

Fácil de confundir, porque ambos se llaman "provenance":

| | Provenance de BuildKit | Artifact attestation de GitHub |
|---|---|---|
| Quién la genera | Buildx, automático | `actions/attest`, explícito |
| Dónde vive | Dentro del índice (`unknown/unknown`) | Store de GitHub + Rekor (+ registry si `push-to-registry`) |
| Firmada | ❌ | ✅ Sigstore, certificado efímero |
| Verificable por terceros | ❌ | ✅ `gh attestation verify` |
| Qué prueba | Nada — es autodeclarada | Que ese digest salió de ese workflow |

La primera **describe**. La segunda **prueba**. Sin firma, cualquiera con credenciales de escritura en el registry puede publicar una imagen con provenance fabricada.

Desactivar la de BuildKit si molesta el ruido:

```yaml
- uses: docker/build-push-action@v7
  with:
    provenance: false
```

---

## Comandos de inspección por nivel

```bash
IMG=ghcr.io/mantoniocc/node-runtime-base:1.4.1

# Vista general del índice
docker buildx imagetools inspect "$IMG"

# JSON crudo del índice (annotations, lista de manifests)
docker buildx imagetools inspect "$IMG" --raw | python3 -m json.tool

# Solo el digest del índice
docker buildx imagetools inspect "$IMG" | awk '/^Digest:/{print $2; exit}'

# Qué hay en cada entrada del índice
docker buildx imagetools inspect "$IMG" --raw | python3 -c "
import sys, json
for m in json.load(sys.stdin)['manifests']:
    p = m.get('platform', {})
    t = m.get('annotations', {}).get('vnd.docker.reference.type', '-')
    print(f\"{p.get('os','?')}/{p.get('architecture','?'):10} {t}\")
"

# Config de una plataforma (labels, user, entrypoint)
docker buildx imagetools inspect "$IMG" --format '{{json .Image}}' | python3 -m json.tool

# Provenance de BuildKit
docker buildx imagetools inspect "$IMG" --format '{{json .Provenance}}' | python3 -m json.tool

# Pull de una plataforma específica
docker pull --platform linux/arm64 "$IMG"
```

---

## La jerarquía de referencias

| Referencia | Ejemplo | Mutable | Cuándo usarla |
|---|---|---|---|
| Tag mayor | `:1` | Muy | Parches automáticos |
| Tag menor | `:1.4` | Sí | Conservador |
| Tag exacto | `:1.4.1` | Poco, pero sí | Casi producción |
| **Digest** | `@sha256:...` | **Nunca** | Producción, builds reproducibles |

Hasta `:1.4.1` es mutable: nada impide republicar ese tag apuntando a otra imagen. Un tag de contenedor tiene exactamente la misma naturaleza que un tag de Git — un puntero movible — y el mismo vector de ataque asociado.

**Cuando hay digest, el tag se ignora al resolver.** `node:cualquier-cosa@sha256:abc...` trae los mismos bytes que `node:24-slim@sha256:abc...`. El tag junto a un digest es puro comentario **para el resolver** — pero sigue importando para Dependabot, que usa el tag para saber a qué digest nuevo apuntar.

---

## Para seguir estudiando

- **OCI Image Format Specification** — `image-index.md`, `manifest.md`, `config.md`, `descriptor.md`
- **OCI Distribution Specification** — cómo el registry expone estos objetos, y la API de referrers
- **Content-addressable storage** — el modelo que comparten Git, OCI e IPFS
- **SLSA** — niveles de garantía de la cadena de suministro
- **in-toto attestation framework** — el formato de las attestations
- **Sigstore** — Fulcio (CA), Rekor (log de transparencia), keyless signing
- **ORAS** — usar registries OCI para artefactos que no son imágenes

Preguntas abiertas que valen la pena:

- ¿Cómo hace `crane copy` para preservar digests entre registries? ¿Qué pasa con los referrers?
- ¿Por qué las capas se comparten entre imágenes distintas, y cómo lo aprovecha la deduplicación del registry?
- ¿Qué diferencia hay entre el media type de Docker y el de OCI, y por qué siguen coexistiendo?
- ¿Cómo verifica Kyverno una attestation en tiempo de admisión sin llamar a GitHub?