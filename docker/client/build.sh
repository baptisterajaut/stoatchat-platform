#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SCRIPT_DIR}/build.conf"

if [ ! -f "${CONF}" ]; then
    echo "Error: config file not found: ${CONF}" >&2
    exit 1
fi
# shellcheck source=build.conf
source "${CONF}"

IMAGE="${STOATCHAT_WEBCLIENT_IMAGE_PUBLISHNAME:-${WEB_IMAGE}}"
TAG="${1:-dev}"
REF="${STOATCHAT_WEB_REF:-${WEB_REF}}"
REPO="${WEB_REPO}"
ASSETS="${ASSETS_REPO}"

if command -v nerdctl &> /dev/null; then
    CTR=nerdctl
elif command -v docker &> /dev/null; then
    CTR=docker
else
    echo "Error: neither nerdctl nor docker found"
    exit 1
fi

echo "Using ${CTR}"
echo "Building ${IMAGE}:${TAG} (repo: ${REPO}, ref: ${REF}, assets: ${ASSETS})"

${CTR} build \
    --platform linux/amd64 \
    --build-arg STOATCHAT_WEB_REF="${REF}" \
    --build-arg STOATCHAT_WEB_REPO="${REPO}" \
    --build-arg STOATCHAT_ASSETS_REPO="${ASSETS}" \
    --build-arg CACHE_BUST="$(date +%s)" \
    -t "${IMAGE}:${TAG}" \
    "${SCRIPT_DIR}"

echo ""
read -rp "Push ${IMAGE}:${TAG}? [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
    ${CTR} push "${IMAGE}:${TAG}"
    echo "Pushed ${IMAGE}:${TAG}"
fi
