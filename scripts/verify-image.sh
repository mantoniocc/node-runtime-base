#!/usr/bin/env bash
#
# Verifica el contrato de la imagen base.
# Uso: ./scripts/verify-image.sh <referencia-de-imagen>
#
set -euo pipefail

IMAGE="${1:?Uso: $0 <imagen>}"
EXPECTED_UID=1000
EXPECTED_NODE_MAJOR=24
EXPECTED_DISTRO_CODENAME=bookworm

FAILED=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name"
    FAILED=1
  fi
}

echo "Verificando contrato de: $IMAGE"
echo

echo "Usuario:"
ACTUAL_UID="$(docker run --rm "$IMAGE" id -u)"
if [ "$ACTUAL_UID" = "$EXPECTED_UID" ]; then
  echo "  ✓ corre como UID $EXPECTED_UID (no-root)"
else
  echo "  ✗ corre como UID $ACTUAL_UID, se esperaba $EXPECTED_UID"
  FAILED=1
fi

echo
echo "Runtime:"
NODE_VER="$(docker run --rm "$IMAGE" node --version)"
if [[ "$NODE_VER" == v${EXPECTED_NODE_MAJOR}.* ]]; then
  echo "  ✓ Node $NODE_VER"
else
  echo "  ✗ Node $NODE_VER, se esperaba v${EXPECTED_NODE_MAJOR}.x"
  FAILED=1
fi
check "npm disponible" docker run --rm "$IMAGE" npm --version

echo
echo "Init y señales:"
PID1="$(docker run --rm "$IMAGE" cat /proc/1/comm | tr -d '[:space:]')"
if [ "$PID1" = "tini" ]; then
  echo "  ✓ tini es PID 1"
else
  echo "  ✗ PID 1 es '$PID1', se esperaba tini"
  FAILED=1
fi

CID="$(docker run -d "$IMAGE" node -e 'setInterval(()=>{},1000)')"
START=$(date +%s)
docker stop "$CID" >/dev/null
ELAPSED=$(( $(date +%s) - START ))
docker rm "$CID" >/dev/null
if [ "$ELAPSED" -le 3 ]; then
  echo "  ✓ SIGTERM propagado (${ELAPSED}s)"
else
  echo "  ✗ tardó ${ELAPSED}s en parar — señales no propagadas"
  FAILED=1
fi

echo
echo "Sistema:"
DISTRO="$(docker run --rm "$IMAGE" \
  sh -c '. /etc/os-release && echo "$VERSION_CODENAME"' | tr -d '[:space]')"
if [ "$DISTRO" = "$EXPECTED_DISTRO_CODENAME" ]; then
  echo "  ✓ distro base: Debian $DISTRO"
else
  echo "  ✗ distro base: '$DISTRO', se esperaba '$EXPECTED_DISTRO_CODENAME'"
  echo "    Un cambio de distro es MAJOR. Si es intencional, actualizá"
  echo "    EXPECTED_DISTRO_CODENAME y documentalo como breaking change."
  FAILED=1
fi
check "certificados CA presentes" \
  docker run --rm "$IMAGE" node -e "fetch('https://api.github.com').then(r=>process.exit(r.ok?0:1))"
check "/app existe y es escribible" \
  docker run --rm "$IMAGE" sh -c 'touch /app/.probe && rm /app/.probe'
check "sin caché de apt" \
  docker run --rm "$IMAGE" sh -c '[ -z "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]'

echo
echo "Metadata OCI:"
for label in title source revision version licenses; do
  VALUE="$(docker image inspect "$IMAGE" \
    --format "{{index .Config.Labels \"org.opencontainers.image.$label\"}}")"
  if [ -n "$VALUE" ] && [ "$VALUE" != "<no value>" ]; then
    echo "  ✓ image.$label = $VALUE"
  else
    echo "  ✗ image.$label ausente"
    FAILED=1
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "Contrato verificado."
else
  echo "El contrato NO se cumple."
  exit 1
fi