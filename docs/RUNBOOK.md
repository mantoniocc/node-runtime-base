# Runbook — node-runtime-base

Imagen base publicada en GHCR. Operación y mantenimiento.

---

## Publicar una versión

1. Mergear a `main` y esperar CI verde.
2. Crear el tag y el Release:

       git tag vX.Y.Z
       git push origin vX.Y.Z
       gh release create vX.Y.Z --generate-notes --verify-tag

3. Verificar que el job `Publicar en GHCR` termine en verde.

El tag es la **única fuente de verdad** de la versión: no hay archivo con un número que pueda divergir. El guard de `release.yml` valida que el formato sea SemVer y aborta si no.

`--verify-tag` evita que `gh` cree el tag por su cuenta desde el commit equivocado.

## Criterio de versionado

El contrato de la imagen define qué es breaking. Todo lo listado en la tabla de contrato del README es una promesa a los consumidores.

| Cambio | Bump |
|---|---|
| Parche de seguridad del upstream (mismo Node major, misma distro) | **patch** |
| Node minor (24.5 → 24.6) | **patch** |
| Agregar un paquete de sistema | **minor** |
| Agregar una plataforma (`linux/arm64`) | **minor** |
| Cambiar el UID de `node` | **MAJOR** |
| Cambiar de distro (bookworm → trixie) | **MAJOR** |
| Node major (24 → 26) | **MAJOR** |
| Quitar `tini` o cambiar el ENTRYPOINT | **MAJOR** |
| Quitar una plataforma | **MAJOR** |
| Agregar `CMD` o `NODE_ENV` | **MAJOR** — rompe multi-stage de consumidores |

Los tags móviles (`:1`, `:1.4`, `:latest`) se mueven automáticamente. Un MAJOR que mueva `:1` a otra distro rompería a todos los anclados a ese tag: por eso un MAJOR debe abrir una nueva línea (`:2`) y anunciarse.

## Prereleases

`metadata-action` no aplica tags móviles ni `latest` a versiones con guion:

    v2.0.0-rc.1  →  publica solo :2.0.0-rc.1

Es el comportamiento correcto: un RC nunca debe llegar a quien está anclado a `:2`.

---

## Actualizar la base upstream

El `FROM` está anclado por digest al **índice multi-arquitectura**, no a un manifest de plataforma. Anclar a un manifest rompería el build multi-arch.

Dependabot abre un PR semanal (lunes). Antes de mergear:

1. Confirmar que el CI está verde — incluye el check de `VERSION_CODENAME=bookworm`.
2. Revisar el changelog del upstream si el salto es grande.
3. Mergear y publicar un **patch**.

Obtener un digest a mano:

    docker buildx imagetools inspect node:24-bookworm-slim \
      | awk '/^Digest:/{print $2; exit}'

Verificar que sea un índice y no un manifest:

    docker buildx imagetools inspect "node:24-bookworm-slim@$DIGEST" | head -3
    # debe decir: MediaType: application/vnd.oci.image.index.v1+json

**El tag `24-bookworm-slim` es explícito a propósito.** Con un digest presente el tag no se consulta al resolver, pero define la vía de actualización de Dependabot: pinnear `24-slim` haría que una migración de distro llegara como un PR indistinguible de un parche.

---

## Verificar el contrato

    ./scripts/verify-image.sh <referencia>

14 aserciones. Funciona igual sobre una imagen local o una del registry:

    ./scripts/verify-image.sh node-runtime-base:dev
    ./scripts/verify-image.sh ghcr.io/mantoniocc/node-runtime-base:1.4.1

**Limitación conocida:** solo verifica la plataforma nativa del host. En CI eso significa que **arm64 se publica sin verificar** (issue abierto).

Cada afirmación del contrato necesita un check que la pruebe. Si agregás una garantía al README, agregá su check al script — las declaraciones sin verificación se erosionan.

---

## Versión con problemas

Las imágenes publicadas son inmutables: **nunca republicar un tag exacto ni borrar una versión.** Borrar rompe a cualquiera que la tenga en un `FROM` o en un lockfile de despliegue.

En su lugar:

1. Publicar el fix como versión nueva.
2. Los tags móviles (`:1`, `:1.4`, `:latest`) se reapuntan solos.
3. Comunicar a los consumidores anclados por digest.

Borrado justificado solo ante: secretos filtrados en una capa, o contenido que legalmente no se puede distribuir. Y aun así, primero rotar el secreto — asumir que ya fue copiado.

---

## Limpieza de versiones

`cleanup-packages.yml` corre los domingos. Simular antes de ejecutar:

    gh workflow run cleanup-packages.yml -f dry_run=true

Tres salvaguardas:

- `min-versions-to-keep: 20` — piso absoluto
- `ignore-versions` protege tags SemVer, `latest` y **los referrers `sha256-*`**
- `dry_run: true` por defecto

**Los tags `sha256-*` son las attestations**, no imágenes. Borrarlos elimina la verificación desde el registry. Nunca sacarlos del `ignore-versions`.

Inventario:

    gh api /user/packages/container/node-runtime-base/versions \
      --jq '.[] | "\(.created_at)  \(.metadata.container.tags | join(", ") // "(sin tags)")"'

Una imagen multi-arch consume ~5 versiones: 1 índice + 2 manifests + 2 attestations de BuildKit. Ver `docs/MANIFESTS.md`.

---

## Verificar procedencia

    gh attestation verify \
      oci://ghcr.io/mantoniocc/node-runtime-base:X.Y.Z \
      --owner mantoniocc

Sin `--predicate-type`, valida **solo provenance**. Para el SBOM:

    gh attestation verify \
      oci://ghcr.io/mantoniocc/node-runtime-base:X.Y.Z \
      --owner mantoniocc \
      --predicate-type https://spdx.dev/Document

Extraer el inventario de paquetes:

    gh attestation verify oci://... --owner mantoniocc \
      --predicate-type https://spdx.dev/Document --format json \
      | python3 -c "
    import sys, json
    d = json.load(sys.stdin)
    pkgs = d[0]['verificationResult']['statement']['predicate']['packages']
    print(f'{len(pkgs)} paquetes')
    "

Útil ante un CVE: responde "¿esta imagen contiene el paquete afectado?" sin descargarla.

---

## Dar acceso a otro repositorio

Solo necesario si la imagen fuera **privada**. Siendo pública, cualquiera puede hacer `FROM` sin credenciales.

Si fuera privada, el `GITHUB_TOKEN` de otro repo **no alcanza**: está scopeado a su propio repositorio. La solución correcta no es un PAT:

    Packages → node-runtime-base → Package settings
    → Manage Actions access → Add repository

Eso permite que el `GITHUB_TOKEN` del repo agregado lea la imagen. Sin secretos que rotar.

Un package de GHCR vive bajo la **cuenta**, no bajo el repo. La herencia de permisos del repositorio es el default inicial, no un vínculo estructural: se puede desacoplar y extender.

---

## Workflows

| Archivo | Trigger | Qué hace |
|---|---|---|
| `ci.yml` | push / PR a `main` | Build amd64, verifica contrato. **No publica** — no tiene `packages: write` |
| `release.yml` | `release: published` | Valida SemVer, build, verifica, push multi-arch, attestations |
| `cleanup-packages.yml` | cron dominical | Poda versiones viejas con salvaguardas |

`ci.yml` y `release.yml` duplican la lógica de build. Deben mantenerse sincronizados o el CI validaría algo distinto de lo que se publica (issue abierto: extraer a reusable workflow).

---

## Orden de operaciones en `release.yml`

No es arbitrario:

    build (load, amd64)  →  verify  →  build multi-arch + push  →  attest
                                              ↑ amd64 sale de cache

**El gate está antes del push.** Si el contrato falla, nada se publica.

**La attestation va después del push** porque firma el digest publicado. Si fuera antes, no habría digest que firmar.

**La cache no es solo velocidad:** es lo que garantiza que el amd64 publicado sea el verificado. Sin `cache-to: type=gha,mode=max`, ambos builds correrían por separado y podrían diferir.