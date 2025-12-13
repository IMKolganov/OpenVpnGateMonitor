#!/bin/bash
set -e

DOCKER_USER="imkolganov"
BUILD_CONFIG="Release"
BUILDER_NAME="multiarch-builder"
FRONT_TAG="latest"

ALL_SERVICES=("backend" "telegrambot" "openvpn" "frontend")

docker buildx inspect ${BUILDER_NAME} >/dev/null 2>&1 || {
  echo "🧱 Creating buildx builder '${BUILDER_NAME}'..."
  docker buildx create --name ${BUILDER_NAME} --use
  docker buildx inspect --bootstrap
}

build_and_push_dotnet() {
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

build_and_push_frontend() {
  echo "🎨 Building frontend for amd64 + arm64..."
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t ${DOCKER_USER}/openvpn-gate-monitor-frontend:${FRONT_TAG} \
    --push \
    ./frontend
  echo "✅ Frontend built and pushed as: ${DOCKER_USER}/openvpn-gate-monitor-frontend:${FRONT_TAG}"
}

# If no args -> build all
if [[ $# -eq 0 ]]; then
  SERVICES=("${ALL_SERVICES[@]}")
else
  SERVICES=("$@")
fi

for SVC in "${SERVICES[@]}"; do
  case "$SVC" in
    backend|telegrambot|openvpn) build_and_push_dotnet "$SVC" ;;
    frontend) build_and_push_frontend ;;
    *)
      echo "❌ Unknown service: $SVC"
      echo "Allowed: ${ALL_SERVICES[*]}"
      exit 1
      ;;
  esac
done
