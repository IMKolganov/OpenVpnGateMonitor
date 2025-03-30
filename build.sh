#!/bin/bash

set -e

# ─── CONFIGURATION ──────────────────────────────────────────────────────
DOCKER_USER="imkolganov"
BUILD_CONFIG="Release"
BUILDER_NAME="multiarch-builder"
FRONT_TAG="latest"

# ─── CREATE BUILDX BUILDER IF NOT EXISTS ───────────────────────────────
docker buildx inspect ${BUILDER_NAME} >/dev/null 2>&1 || {
    echo "🧱 Creating buildx builder '${BUILDER_NAME}'..."
    docker buildx create --name ${BUILDER_NAME} --use
    docker buildx inspect --bootstrap
}

# ─── FUNCTION TO BUILD AND PUSH MULTIARCH SERVICES ─────────────────────
build_and_push() {
    local SERVICE=$1
    local IMAGE_NAME="${DOCKER_USER}/openvpn-gate-monitor-${SERVICE}"

    for ARCH in amd64 arm64; do
        local TARGETARCH
        [[ "$ARCH" == "amd64" ]] && TARGETARCH=x64 || TARGETARCH=arm64

        echo "🚀 Building ${SERVICE} for ${ARCH}..."

        docker buildx build \
            --platform linux/${ARCH} \
            --build-arg TARGETARCH=${TARGETARCH} \
            --build-arg BUILD_CONFIGURATION=${BUILD_CONFIG} \
            -t ${IMAGE_NAME}:${ARCH} \
            --push \
            ./${SERVICE}
    done

    echo "🔗 Creating multi-arch manifest for ${SERVICE}..."
    docker buildx imagetools create \
        --tag ${IMAGE_NAME}:latest \
        ${IMAGE_NAME}:amd64 \
        ${IMAGE_NAME}:arm64

    echo "✅ ${SERVICE} built and pushed as: ${IMAGE_NAME}:latest"
}

# ─── BUILD BACKEND ──────────────────────────────────────────────────────
build_and_push backend

# ─── BUILD TELEGRAM BOT ─────────────────────────────────────────────────
build_and_push telegrambot

# ─── BUILD FRONTEND (MULTIARCH) ─────────────────────────────────────────
echo "🎨 Building frontend for amd64 + arm64..."

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t ${DOCKER_USER}/openvpn-gate-monitor-frontend:${FRONT_TAG} \
    --push \
    ./frontend

echo "✅ Frontend built and pushed as: ${DOCKER_USER}/openvpn-gate-monitor-frontend:${FRONT_TAG}"
