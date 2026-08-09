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

progress_bar() {
  local done=$1 total=$2 width=${3:-20}
  local filled=0 empty=0
  if (( total > 0 )); then
    filled=$(( done * width / total ))
  fi
  empty=$(( width - filled ))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf ']'
}

# Reap background builds with a live progress board (N/total) until all finish.
reap_parallel_builds() {
  local -n _pids=$1
  local -n _names=$2
  local _logdir=$3
  local -n _ok_out=$4
  local -n _fail_out=$5
  local _total=$6
  local -n _start_times=$7
  local _wall_start=${8:-$(date +%s)}

  declare -A _pid_to_name=()
  declare -A _name_to_pid=()
  declare -A _status=() # pending|running|ok|fail
  declare -A _exit_rc=()
  local i _done=0 _last_board=0
  local svc pid

  for i in "${!_pids[@]}"; do
    pid="${_pids[$i]}"
    svc="${_names[$i]}"
    _pid_to_name[$pid]="$svc"
    _name_to_pid[$svc]="$pid"
    _status[$svc]="running"
  done

  clear_status_block() {
    # Erase previous live board (status lines + progress + blank).
    local lines=${1:-0}
    local n
    for (( n = 0; n < lines; n++ )); do
      printf '\033[1A\033[2K'
    done
  }

  draw_status_board() {
    local now elapsed running=() board_lines=0
    now=$(date +%s)
    elapsed=$(( now - _wall_start ))

    for svc in "${_names[@]}"; do
      if [[ "${_status[$svc]}" == "running" ]]; then
        running+=("$svc")
      fi
    done

    echo "┌─ Progress $(progress_bar "$_done" "$_total") ${_done}/${_total} · wall $(format_duration "$elapsed")"
    ((board_lines++)) || true
    for svc in "${_names[@]}"; do
      local st="${_status[$svc]}"
      local svc_elapsed=$(( now - ${_start_times[$svc]:-$now} ))
      local icon="⏳" label="running" tail=""
      case "$st" in
        ok) icon="✅"; label="ok" ;;
        fail) icon="❌"; label="failed" ;;
        running)
          icon="⏳"
          label="running"
          if [[ -f "${_logdir}/${svc}.step" ]]; then
            tail="$(tr -d '\r' <"${_logdir}/${svc}.step" | head -n 1 | cut -c1-64 || true)"
          elif [[ -f "${_logdir}/${svc}.log" ]]; then
            tail="$(tail -n 1 "${_logdir}/${svc}.log" 2>/dev/null | tr -d '\r' | cut -c1-64 || true)"
          fi
          ;;
      esac
      if [[ "$st" == "running" && -n "$tail" ]]; then
        printf '│ %s %-12s %-7s %5s  %s\n' "$icon" "$svc" "$label" "$(format_duration "$svc_elapsed")" "$tail"
      else
        printf '│ %s %-12s %-7s %5s\n' "$icon" "$svc" "$label" "$(format_duration "$svc_elapsed")"
      fi
      ((board_lines++)) || true
    done
    if (( ${#running[@]} > 0 )); then
      echo "└─ still running: ${running[*]}"
    else
      echo "└─ all jobs finished"
    fi
    ((board_lines++)) || true
    _last_board=$board_lines
  }

  report_build_finish() {
    local svc=$1 rc=$2
    local elapsed=$(( $(date +%s) - ${_start_times[$svc]:-$(date +%s)} ))
    ((_done++)) || true
    if [[ "$rc" -eq 0 ]]; then
      _status[$svc]="ok"
      _ok_out+=("$svc")
      echo "✅ [${_done}/${_total}] Finished: $svc ($(format_duration "$elapsed"))"
    else
      _status[$svc]="fail"
      _exit_rc[$svc]=$rc
      _fail_out+=("$svc")
      echo "❌ [${_done}/${_total}] Failed: $svc (exit $rc, $(format_duration "$elapsed"))"
      echo "--- tail ${_logdir}/${svc}.log (last 80 lines) ---"
      tail -n 80 "${_logdir}/${svc}.log" 2>/dev/null || true
      echo "--- (full log: ${_logdir}/${svc}.log) ---"
    fi
    _last_board=0
  }

  # Initial board
  draw_status_board

  while ((_done < _total)); do
    local progressed=0
    for i in "${!_pids[@]}"; do
      pid="${_pids[$i]}"
      svc="${_names[$i]}"
      [[ "${_status[$svc]}" == "running" ]] || continue
      if ! kill -0 "$pid" 2>/dev/null; then
        local rc=0
        wait "$pid" || rc=$?
        if (( _last_board > 0 )); then
          clear_status_block "$_last_board"
          _last_board=0
        fi
        report_build_finish "$svc" "$rc"
        progressed=1
      fi
    done

    if (( progressed )); then
      if ((_done < _total)); then
        draw_status_board
      fi
    else
      # Refresh live board ~every second while waiting
      if (( _last_board > 0 )); then
        clear_status_block "$_last_board"
      fi
      draw_status_board
      sleep 1
    fi
  done
}

parallel_fail_strict() {
  [[ "${BUILD_FAIL_SOFT:-1}" == "0" || "${BUILD_FAIL_SOFT,,}" == "false" || "${BUILD_FAIL_SOFT,,}" == "no" ]]
}

# Per-service step tracker (log + optional status file for the live board).
service_step() {
  local step=$1 total=$2 msg=$3
  local line="▸ [${step}/${total}] ${msg}"
  echo "$line"
  if [[ -n "${BUILD_STEP_FILE:-}" ]]; then
    printf '%s\n' "${step}/${total} ${msg}" >"${BUILD_STEP_FILE}.tmp"
    mv -f "${BUILD_STEP_FILE}.tmp" "${BUILD_STEP_FILE}"
  fi
}

service_plan() {
  local title=$1
  shift
  local steps=("$@")
  local n=${#steps[@]} i=0
  echo "── ${title}: ${n} steps ──"
  for s in "${steps[@]}"; do
    ((i++)) || true
    echo "  ${i}/${n}  ${s}"
  done
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
  local STEPS=(
    "Check Dockerfile"
    "Build & push linux/amd64"
    "Build & push linux/arm64"
    "Create multi-arch manifest (:latest)"
    "Done"
  )
  local TOTAL=${#STEPS[@]}

  service_plan "${SERVICE}" "${STEPS[@]}"

  service_step 1 "$TOTAL" "${STEPS[0]}"
  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "❌ Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi
  echo "   found ${DOCKERFILE}"

  local ARCH TARGETARCH step_i=2
  for ARCH in amd64 arm64; do
    [[ "$ARCH" == "amd64" ]] && TARGETARCH=x64 || TARGETARCH=arm64
    service_step "$step_i" "$TOTAL" "${STEPS[$((step_i - 1))]}"
    echo "   image ${IMAGE_NAME}:${ARCH} (TARGETARCH=${TARGETARCH}, config=${BUILD_CONFIG})"
    docker buildx build \
      --platform "linux/${ARCH}" \
      --build-arg "TARGETARCH=${TARGETARCH}" \
      --build-arg "BUILD_CONFIGURATION=${BUILD_CONFIG}" \
      -f "${DOCKERFILE}" \
      -t "${IMAGE_NAME}:${ARCH}" \
      --push \
      "${CONTEXT}"
    echo "   pushed ${IMAGE_NAME}:${ARCH}"
    ((step_i++)) || true
  done

  service_step 4 "$TOTAL" "${STEPS[3]}"
  echo "   tag ${IMAGE_NAME}:latest ← amd64 + arm64"
  docker buildx imagetools create \
    --tag "${IMAGE_NAME}:latest" \
    "${IMAGE_NAME}:amd64" \
    "${IMAGE_NAME}:arm64"
  echo "   manifest ready"

  service_step 5 "$TOTAL" "${STEPS[4]}"
  echo "✅ ${SERVICE} built and pushed as: ${IMAGE_NAME}:latest"
}

build_and_push_frontend() {
  local CONTEXT="${REPO_ROOT}/frontend"
  local DOCKERFILE="${CONTEXT}/Dockerfile"
  local IMAGE_NAME="${DOCKER_USER}/${IMAGE_PREFIX}-frontend"
  # Split comma-separated platforms into per-arch build+push, then a final tag step when multi-arch.
  local -a PLAT_LIST=()
  IFS=',' read -r -a PLAT_LIST <<<"${FRONTEND_PLATFORMS}"
  local -a NORM_PLATS=()
  local p
  for p in "${PLAT_LIST[@]}"; do
    # trim whitespace
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "$p" ]] || continue
    NORM_PLATS+=("$p")
  done
  if (( ${#NORM_PLATS[@]} == 0 )); then
    NORM_PLATS=("linux/amd64")
  fi

  local -a STEPS=("Check Dockerfile")
  for p in "${NORM_PLATS[@]}"; do
    STEPS+=("Build & push ${p}")
  done
  if (( ${#NORM_PLATS[@]} > 1 )); then
    STEPS+=("Create multi-arch tag :${FRONT_TAG}")
  fi
  STEPS+=("Done")
  local TOTAL=${#STEPS[@]}

  service_plan "frontend" "${STEPS[@]}"

  local step=1
  service_step "$step" "$TOTAL" "${STEPS[$((step - 1))]}"
  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "❌ Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi
  echo "   found ${DOCKERFILE}"
  ((step++)) || true

  local -a ARCH_TAGS=()
  local plat arch_tag
  for plat in "${NORM_PLATS[@]}"; do
    service_step "$step" "$TOTAL" "${STEPS[$((step - 1))]}"
    arch_tag="${plat##*/}" # linux/amd64 -> amd64
    ARCH_TAGS+=("${IMAGE_NAME}:${arch_tag}")
    echo "   image ${IMAGE_NAME}:${arch_tag} (platform ${plat})"
    docker buildx build \
      --platform "${plat}" \
      -f "${DOCKERFILE}" \
      -t "${IMAGE_NAME}:${arch_tag}" \
      --push \
      "${CONTEXT}"
    echo "   pushed ${IMAGE_NAME}:${arch_tag}"
    ((step++)) || true
  done

  if (( ${#NORM_PLATS[@]} > 1 )); then
    service_step "$step" "$TOTAL" "${STEPS[$((step - 1))]}"
    echo "   tag ${IMAGE_NAME}:${FRONT_TAG} ← ${ARCH_TAGS[*]}"
    docker buildx imagetools create \
      --tag "${IMAGE_NAME}:${FRONT_TAG}" \
      "${ARCH_TAGS[@]}"
    echo "   manifest ready"
    ((step++)) || true
  else
    # Single platform: also tag as FRONT_TAG (often "latest") for compose defaults.
    local only_tag="${ARCH_TAGS[0]}"
    if [[ "${only_tag}" != "${IMAGE_NAME}:${FRONT_TAG}" ]]; then
      echo "   tagging ${only_tag} → ${IMAGE_NAME}:${FRONT_TAG}"
      docker buildx imagetools create \
        --tag "${IMAGE_NAME}:${FRONT_TAG}" \
        "${only_tag}"
    fi
  fi

  service_step "$step" "$TOTAL" "Done"
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
  total=${#SERVICES[@]}
  echo "⚡ Parallel build — ${total} services"
  echo "Outer plan:"
  step=0
  for SVC in "${SERVICES[@]}"; do
    ((step++)) || true
    case "$SVC" in
      frontend)
        echo "  ${step}/${total}  $SVC  (check → build&push per platform → tag → done)"
        ;;
      *)
        echo "  ${step}/${total}  $SVC  (check → amd64 build&push → arm64 build&push → manifest → done)"
        ;;
    esac
  done
  LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/datagate-monitor-build.XXXXXX")"
  echo "📋 Per-service logs: ${LOG_DIR}"
  BUILD_WALL_START=$(date +%s)
  pids=()
  names=()
  declare -A service_start_times=()
  PARALLEL_INTERRUPTED=0

  cleanup_parallel_jobs() {
    PARALLEL_INTERRUPTED=1
    echo ""
    echo "⚠️  Interrupted (Ctrl+C) — stopping ${#pids[@]} build job(s)…"
    local pid
    for pid in "${pids[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${pids[@]}"; do
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_parallel_jobs INT TERM

  step=0
  for SVC in "${SERVICES[@]}"; do
    ((step++)) || true
    service_start_times[$SVC]=$(date +%s)
    printf '1/? starting…\n' >"${LOG_DIR}/${SVC}.step"
    (
      export BUILD_STEP_FILE="${LOG_DIR}/${SVC}.step"
      build_one_service "$SVC"
    ) >"${LOG_DIR}/${SVC}.log" 2>&1 &
    pids+=($!)
    names+=("$SVC")
    echo "▶️  [${step}/${total}] Started: $SVC (pid $!)"
  done
  echo ""

  ok=()
  fail=()
  reap_parallel_builds pids names "$LOG_DIR" ok fail "$total" service_start_times "$BUILD_WALL_START"
  trap - INT TERM
  BUILD_WALL_ELAPSED=$(( $(date +%s) - BUILD_WALL_START ))

  if (( PARALLEL_INTERRUPTED )); then
    echo "──────── Summary (interrupted) ────────"
    echo "⏱  Wall time: $(format_duration "$BUILD_WALL_ELAPSED")"
    printf "✅ OK (%d/%d): %s\n" "${#ok[@]}" "$total" "${ok[*]:-(none)}"
    printf "❌ Failed/stopped (%d): %s\n" "$(( total - ${#ok[@]} ))" "${fail[*]:-remaining jobs killed}"
    exit 130
  fi

  echo "──────── Summary ────────"
  echo "⏱  Total wall time: $(format_duration "$BUILD_WALL_ELAPSED") (parallel)"
  printf "✅ OK (%d/%d): %s\n" "${#ok[@]}" "$total" "${ok[*]:-(none)}"
  printf "❌ Failed (%d/%d): %s\n" "${#fail[@]}" "$total" "${fail[*]:-(none)}"

  if (( ${#fail[@]} > 0 )); then
    echo "💡 Hint: parallel pushes can hit registry rate limits (HTTP 429); retry failed service alone or use sequential build."
  fi

  if (( ${#fail[@]} == 0 )); then
    rm -rf "${LOG_DIR}"
    echo "🎉 All ${total}/${total} services built."
    exit 0
  fi

  if parallel_fail_strict || (( ${#ok[@]} == 0 )); then
    exit 1
  fi

  echo "⚠️ BUILD_FAIL_SOFT=1: partial success (${#ok[@]}/${total} ok, ${#fail[@]} failed) — exiting 0. Logs: ${LOG_DIR}"
  exit 0
else
  BUILD_WALL_START=$(date +%s)
  total=${#SERVICES[@]}
  echo "🧱 Sequential build — ${total} services"
  done_count=0
  for SVC in "${SERVICES[@]}"; do
    ((done_count++)) || true
    echo ""
    echo "▶️  [${done_count}/${total}] Building $SVC…"
    svc_start=$(date +%s)
    unset BUILD_STEP_FILE
    build_one_service "$SVC"
    svc_elapsed=$(( $(date +%s) - svc_start ))
    echo "✅ [${done_count}/${total}] Finished: $SVC ($(format_duration "$svc_elapsed"))"
  done
  BUILD_WALL_ELAPSED=$(( $(date +%s) - BUILD_WALL_START ))
  echo ""
  echo "──────── Summary ────────"
  echo "⏱  Total time: $(format_duration "$BUILD_WALL_ELAPSED") (sequential)"
  echo "🎉 All ${total}/${total} services built."
fi
