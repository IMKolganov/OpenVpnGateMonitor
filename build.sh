#!/bin/bash
set -euo pipefail

# Repository root = directory of this script (works when cwd is not the monorepo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER_USER="${DOCKER_USER:-imkolganov}"
# Image: ${DOCKER_USER}/${IMAGE_PREFIX}-<service>. Default matches docker-compose*.yml; override when retagging.
IMAGE_PREFIX="${IMAGE_PREFIX:-datagate-monitor}"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
BUILDER_NAME="${BUILDER_NAME:-multiarch-builder}"
FRONT_TAG="${FRONT_TAG:-latest}"
# Frontend image platforms (comma-separated). Default is amd64 only — fast on typical x86 runners
# and laptops. arm64 under QEMU is very slow (~10+ min). For Docker Hub multi-arch manifest:
#   FRONTEND_PLATFORMS=linux/amd64,linux/arm64 ./build.sh frontend
FRONTEND_PLATFORMS="${FRONTEND_PLATFORMS:-linux/amd64}"
# Run multiple service builds at once (separate processes). Heavy on CPU/RAM/Docker; opt-out:
#   BUILD_PARALLEL=0 ./build.sh backend xray
#   ./build.sh --no-parallel backend openvpn xray
BUILD_PARALLEL="${BUILD_PARALLEL:-1}"
# Parallel: if some services fail, still exit 0 when at least one succeeded (local-friendly).
# CI strict: BUILD_FAIL_SOFT=0
BUILD_FAIL_SOFT="${BUILD_FAIL_SOFT:-1}"

ALL_SERVICES=("backend" "telegrambot" "openvpn" "xray" "frontend")

bash_supports_wait_n() {
  ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))
}

format_duration() {
  local secs=$1
  if (( secs < 60 )); then
    printf '%ds' "$secs"
  elif (( secs < 3600 )); then
    printf '%dm %ds' $((secs / 60)) $((secs % 60))
  else
    printf '%dh %dm' $((secs / 3600)) $(((secs % 3600) / 60))
  fi
}

# Reap background build jobs in completion order (bash 5.1+ wait -n -p), else FIFO wait.
reap_parallel_builds() {
  local -n _pids=$1
  local -n _names=$2
  local _logdir=$3
  local -n _ok_out=$4
  local -n _fail_out=$5
  local _total=$6
  local -n _start_times=$7

  declare -A _pid_to_name=()
  local i _n=${#_pids[@]} _done=0
  for i in "${!_pids[@]}"; do
    _pid_to_name[${_pids[$i]}]="${_names[$i]}"
  done

  report_build_finish() {
    local svc=$1 rc=$2
    local elapsed=$(( $(date +%s) - ${_start_times[$svc]:-$(date +%s)} ))
    ((_done++)) || true
    local progress="[$_done/$_total]"
    if [[ "$rc" -eq 0 ]]; then
      _ok_out+=("$svc")
      echo "✅ Finished: $svc ($(format_duration "$elapsed")) $progress"
    else
      _fail_out+=("$svc")
      echo "❌ Build failed: $svc (exit $rc, $(format_duration "$elapsed")) $progress"
      echo "--- tail ${_logdir}/${svc}.log (last 120 lines) ---"
      tail -n 120 "${_logdir}/${svc}.log" 2>/dev/null || true
      echo "--- (full log: ${_logdir}/${svc}.log) ---"
    fi
  }

  if bash_supports_wait_n; then
    while ((_n > 0)); do
      local WPID="" rc=0 svc=""
      wait -n -p WPID
      rc=$?
      svc="${_pid_to_name[$WPID]:-pid-$WPID}"
      report_build_finish "$svc" "$rc"
      ((_n--)) || true
    done
  else
    echo "ℹ️ Bash < 5.1: reaping parallel jobs in start order (install bash 5.1+ for completion-order waits)."
    for i in "${!_pids[@]}"; do
      local rc=0 svc="${_names[$i]}"
      if wait "${_pids[$i]}"; then
        report_build_finish "$svc" 0
      else
        rc=$?
        report_build_finish "$svc" "$rc"
      fi
    done
  fi
}

parallel_fail_strict() {
  [[ "${BUILD_FAIL_SOFT:-1}" == "0" || "${BUILD_FAIL_SOFT,,}" == "false" || "${BUILD_FAIL_SOFT,,}" == "no" ]]
}

docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1 || {
  echo "🧱 Creating buildx builder '${BUILDER_NAME}'..."
  docker buildx create --name "${BUILDER_NAME}" --use
  docker buildx inspect --bootstrap
}

build_and_push_dotnet() {
  local SERVICE=$1
  local CONTEXT="${REPO_ROOT}/${SERVICE}"
  local DOCKERFILE="${CONTEXT}/Dockerfile"
  local IMAGE_NAME="${DOCKER_USER}/${IMAGE_PREFIX}-${SERVICE}"

  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "❌ Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi

  for ARCH in amd64 arm64; do
    local TARGETARCH
    [[ "$ARCH" == "amd64" ]] && TARGETARCH=x64 || TARGETARCH=arm64

    echo "🚀 Building ${SERVICE} for ${ARCH}..."
    docker buildx build \
      --platform "linux/${ARCH}" \
      --build-arg "TARGETARCH=${TARGETARCH}" \
      --build-arg "BUILD_CONFIGURATION=${BUILD_CONFIG}" \
      -f "${DOCKERFILE}" \
      -t "${IMAGE_NAME}:${ARCH}" \
      --push \
      "${CONTEXT}"
  done

  echo "🔗 Creating multi-arch manifest for ${SERVICE}..."
  docker buildx imagetools create \
    --tag "${IMAGE_NAME}:latest" \
    "${IMAGE_NAME}:amd64" \
    "${IMAGE_NAME}:arm64"

  echo "✅ ${SERVICE} built and pushed as: ${IMAGE_NAME}:latest"
}

build_and_push_frontend() {
  local CONTEXT="${REPO_ROOT}/frontend"
  local DOCKERFILE="${CONTEXT}/Dockerfile"
  local IMAGE_NAME="${DOCKER_USER}/${IMAGE_PREFIX}-frontend"

  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "❌ Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi

  echo "🎨 Building frontend for: ${FRONTEND_PLATFORMS}"
  docker buildx build \
    --platform "${FRONTEND_PLATFORMS}" \
    -f "${DOCKERFILE}" \
    -t "${IMAGE_NAME}:${FRONT_TAG}" \
    --push \
    "${CONTEXT}"
  echo "✅ Frontend built and pushed as: ${IMAGE_NAME}:${FRONT_TAG}"
}

build_one_service() {
  local SVC=$1
  case "$SVC" in
    backend|telegrambot|openvpn|xray) build_and_push_dotnet "$SVC" ;;
    frontend) build_and_push_frontend ;;
    *)
      echo "❌ Unknown service: $SVC"
      echo "Allowed: ${ALL_SERVICES[*]}"
      return 1
      ;;
  esac
}

parallel_enabled() {
  local v="${BUILD_PARALLEL,,}"
  [[ "$v" != "0" && "$v" != "false" && "$v" != "no" && "$v" != "off" ]]
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel|-j) BUILD_PARALLEL=1; shift ;;
    --no-parallel|--sequential) BUILD_PARALLEL=0; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# If no args -> build all
if [[ $# -eq 0 ]]; then
  SERVICES=("${ALL_SERVICES[@]}")
else
  SERVICES=("$@")
fi

for SVC in "${SERVICES[@]}"; do
  case "$SVC" in
    backend|telegrambot|openvpn|xray|frontend) ;;
    *)
      echo "❌ Unknown service: $SVC"
      echo "Allowed: ${ALL_SERVICES[*]}"
      exit 1
      ;;
  esac
done

if parallel_enabled && [[ ${#SERVICES[@]} -gt 1 ]]; then
  echo "⚡ Parallel build for: ${SERVICES[*]} (${#SERVICES[@]} services)"
  LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/datagate-monitor-build.XXXXXX")"
  echo "📋 Per-service logs: ${LOG_DIR}"
  BUILD_WALL_START=$(date +%s)
  pids=()
  names=()
  declare -A service_start_times=()
  for SVC in "${SERVICES[@]}"; do
    service_start_times[$SVC]=$(date +%s)
    ( build_one_service "$SVC" >"${LOG_DIR}/${SVC}.log" 2>&1 ) &
    pids+=($!)
    names+=("$SVC")
    echo "▶️  Started: $SVC (pid $!)"
  done
  ok=()
  fail=()
  reap_parallel_builds pids names "$LOG_DIR" ok fail "${#SERVICES[@]}" service_start_times
  BUILD_WALL_ELAPSED=$(( $(date +%s) - BUILD_WALL_START ))

  echo "──────── Summary ────────"
  echo "⏱  Total wall time: $(format_duration "$BUILD_WALL_ELAPSED") (parallel)"
  printf "✅ OK (%d): %s\n" "${#ok[@]}" "${ok[*]:-(none)}"
  printf "❌ Failed (%d): %s\n" "${#fail[@]}" "${fail[*]:-(none)}"

  if (( ${#fail[@]} > 0 )); then
    echo "💡 Hint: parallel pushes can hit registry rate limits (HTTP 429); retry failed service alone or use sequential build."
  fi

  if (( ${#fail[@]} == 0 )); then
    rm -rf "${LOG_DIR}"
    exit 0
  fi

  if parallel_fail_strict || (( ${#ok[@]} == 0 )); then
    exit 1
  fi

  echo "⚠️ BUILD_FAIL_SOFT=1: partial success (${#ok[@]} ok, ${#fail[@]} failed) — exiting 0. Logs: ${LOG_DIR}"
  exit 0
else
  BUILD_WALL_START=$(date +%s)
  total=${#SERVICES[@]}
  done_count=0
  for SVC in "${SERVICES[@]}"; do
    ((done_count++)) || true
    echo "▶️  Building $SVC [$done_count/$total]..."
    svc_start=$(date +%s)
    build_one_service "$SVC"
    svc_elapsed=$(( $(date +%s) - svc_start ))
    echo "✅ Finished: $SVC ($(format_duration "$svc_elapsed")) [$done_count/$total]"
  done
  BUILD_WALL_ELAPSED=$(( $(date +%s) - BUILD_WALL_START ))
  echo "──────── Summary ────────"
  echo "⏱  Total time: $(format_duration "$BUILD_WALL_ELAPSED") (sequential)"
fi
