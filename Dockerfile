# syntax=docker/dockerfile:1

# Imagen base de plataforma — Node.js 24 sobre Debian bookworm-slim.
#
# CONTRATO: Debian 12 (bookworm). El tag es explícito a propósito.
# Con un digest presente el tag no se consulta al resolver, pero SÍ define
# la vía de actualización de Dependabot: pinnear `24-slim` haría que un
# cambio de distro del upstream (bookworm → trixie) llegara como un PR de
# rutina indistinguible de un parche. Con `24-bookworm-slim` eso no pasa.
#
# Migrar de distro es un cambio MAJOR y una decisión deliberada, no un bump.
# Revisar el EOL de bookworm: https://wiki.debian.org/LTS
FROM node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03

# ------------------------------------------------------------------------------------------
# Capa de sistema
#
# Un solo RUN: cada instruccion crea una capa, y borrar archivos en una capa
# posterior NO reduce el tamaño de la imagen (la capa anterior sigue ahi)
# El rm -rf tiene que ocurrir en el mismo RUN que el apt-get update
# ------------------------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        tini; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*
    
# ------------------------------------------------------------------------------------------
# PID 1
#
# El kernel ignora las señales sin handler explicito cuando van a PID 1.
# Sin un init, `docker stop` espera 10s y manda SIGKILL: rollouts lentos y
# conexiones cortadas de golpe.
#
# tini corre como PID 1, reenvia señales al hijo y reapea zombies.
# Reemplazamos deliberadamente el docker-entrypoint.sh del upstream: una base
# de plataforma no debiera hacer magia con los argumentos del consumidor
# ------------------------------------------------------------------------------------------
ENTRYPOINT [ "/usr/bin/tini", "--" ]

# ------------------------------------------------------------------------------------------
# Usuario sin privilegios
#
# La imagen oficial de Node trae el usuario `node` (UID/GID 1000) pero corre
# como root. Lo activamos
# 
# El UID fijo 1000 es parte del contrato: los consumidores lo necesitan para
# los fsGroups/runAsUser de Kubernetes y para los permisos de volumenes.
# Cambiarlo es un breaking change MAJOR.
# ------------------------------------------------------------------------------------------
RUN set -eux; \
    # Falla el build si el usuario esperado no existe (p. ej. tras un cambio
    # del upstream). Mejor romper aca que publicar una base que corre como root.
    id -u node >/dev/null 2>&1; \
    [ "$(id -u node)" = "1000" ]; \
    mkdir -p /app; \
    chown node:node /app

WORKDIR /app

#USER node
# ------------------------------------------------------------------------------------------
# Entorno
# ------------------------------------------------------------------------------------------
# NO seteamos NODE_ENV: romperia los multi-stage build de los consumidores,
# que necesitan devDependencies para compilar
ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# ------------------------------------------------------------------------------------------
# Metadata OCI
#
# Los ARG los inyecta el CI (ver B2/B3). Los valores por defecto permiten
# construir localmente sin pasarlos.
# ------------------------------------------------------------------------------------------
ARG BUILD_DATE="1970-01-01T00:00:00Z"
ARG VCS_REF="dev"
ARG VERSION="0.0.0-dev"

LABEL org.opencontainers.image.title="node-runtime-base" \
      org.opencontainers.image.description="Imagen base de Node.js 24 hardenizada para la plataforma" \
      org.opencontainers.image.vendor="mantoniocc" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/mantoniocc/node-runtime-base" \
      org.opencontainers.image.documentation="https://github.com/mantoniocc/node-runtime-base#readme" \
      org.opencontainers.image.base.name="docker.io/library/node:24-bookworm-slim" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}"  