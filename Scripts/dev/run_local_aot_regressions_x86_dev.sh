#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/Build-x86dev}"

BUILD_SCRIPT="${SCRIPT_DIR}/build_x86_dev.sh"
GUARDRAIL_SCRIPT="${SCRIPT_DIR}/run_aot_guardrail_x86_dev.sh"
STATIC_SEED_SCRIPT="${SCRIPT_DIR}/build_static_seed_cache_x86_dev.sh"
RUNNER_SCRIPT="${SCRIPT_DIR}/run_x86_dev.sh"

INPUT_DIR="${BUILD_DIR}/Bin"
DO_BUILD=1
KEEP_ARTIFACTS=0
ROOTFS=""
SEED="${SEED:-3735928559}"
SEARCH_PATHS=()
GUARDRAIL_RETRIES=2

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Runs local (non-CI) AOT guardrail regressions:
  1) Optional incremental build of required binaries
  2) JIT-vs-cache parity check via canary
  3) Static codemap+cache generation with dependency resolution
  4) Runtime smoke run using generated static cache set

Options:
  --input-dir PATH      Directory to scan for static seeding (default: ${BUILD_DIR}/Bin)
  --seed VALUE          Canary seed for guardrail parity (default: ${SEED})
  --rootfs PATH         Optional rootfs passed through to static seeding
  --search-path PATH    Additional static resolver search path (repeatable)
  --guardrail-retries N Retry count for guardrail phase on failure (default: ${GUARDRAIL_RETRIES})
  --skip-build          Skip build step and use existing binaries
  --keep-artifacts      Keep temporary codemap/cache directories
  -h, --help            Show this help

Environment overrides:
  BUILD_DIR, SEED
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-dir)
      INPUT_DIR="${2:-}"
      shift 2
      ;;
    --seed)
      SEED="${2:-}"
      shift 2
      ;;
    --rootfs)
      ROOTFS="${2:-}"
      shift 2
      ;;
    --search-path)
      SEARCH_PATHS+=("${2:-}")
      shift 2
      ;;
    --guardrail-retries)
      GUARDRAIL_RETRIES="${2:-}"
      shift 2
      ;;
    --skip-build)
      DO_BUILD=0
      shift
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

for Required in "${GUARDRAIL_SCRIPT}" "${STATIC_SEED_SCRIPT}" "${RUNNER_SCRIPT}"; do
  if [[ ! -x "${Required}" ]]; then
    echo "Missing required script: ${Required}" >&2
    exit 1
  fi
done

if [[ ${DO_BUILD} -eq 1 ]]; then
  if [[ ! -x "${BUILD_SCRIPT}" ]]; then
    echo "Missing build helper: ${BUILD_SCRIPT}" >&2
    exit 1
  fi

  echo "[1/5] Build required binaries"
  "${BUILD_SCRIPT}" --target FEX
  "${BUILD_SCRIPT}" --target FEXStaticCodeMapGen
  "${BUILD_SCRIPT}" --target FEXOfflineCompiler
else
  echo "[1/5] Build step skipped"
fi

echo "[2/5] Guardrail parity (JIT vs cache)"

Attempt=1
while true; do
  set +e
  "${GUARDRAIL_SCRIPT}" --seed "${SEED}"
  RC_GUARDRAIL=$?
  set -e

  if [[ ${RC_GUARDRAIL} -eq 0 ]]; then
    break
  fi

  if [[ ${Attempt} -ge ${GUARDRAIL_RETRIES} ]]; then
    echo "FAIL: guardrail parity failed after ${Attempt} attempt(s)" >&2
    exit ${RC_GUARDRAIL}
  fi

  echo "Guardrail attempt ${Attempt} failed (rc=${RC_GUARDRAIL}), retrying..."
  Attempt=$((Attempt + 1))
done

WORK_DIR="$(mktemp -d -t fex-aot-local-regression-XXXXXX)"
CODEMAP_DIR="${WORK_DIR}/codemaps"
CACHE_DIR="${WORK_DIR}/cache"

cleanup() {
  if [[ ${KEEP_ARTIFACTS} -eq 0 ]]; then
    rm -rf "${WORK_DIR}"
  else
    echo "Kept local regression artifacts: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

mkdir -p "${CODEMAP_DIR}" "${CACHE_DIR}"

echo "[3/5] Static seed codemap+cache generation"
STATIC_ARGS=(
  --input-dir "${INPUT_DIR}"
  --codemap-dir "${CODEMAP_DIR}"
  --cache-dir "${CACHE_DIR}"
)

if [[ -n "${ROOTFS}" ]]; then
  STATIC_ARGS+=(--rootfs "${ROOTFS}")
fi
for SearchPath in "${SEARCH_PATHS[@]}"; do
  STATIC_ARGS+=(--search-path "${SearchPath}")
done

"${STATIC_SEED_SCRIPT}" "${STATIC_ARGS[@]}"

shopt -s nullglob
CodeMaps=("${CODEMAP_DIR}"/*)
Caches=("${CACHE_DIR}"/*)

if [[ ${#CodeMaps[@]} -eq 0 ]]; then
  echo "FAIL: no codemaps generated in ${CODEMAP_DIR}" >&2
  exit 1
fi
if [[ ${#Caches[@]} -eq 0 ]]; then
  echo "FAIL: no caches generated in ${CACHE_DIR}" >&2
  exit 1
fi

CANARY_BIN="${BUILD_DIR}/Bin/aot_canary"
if [[ ! -x "${CANARY_BIN}" ]]; then
  echo "FAIL: expected canary binary missing: ${CANARY_BIN}" >&2
  exit 1
fi

echo "[4/5] Runtime smoke with static cache"
set +e
FEX_APP_CACHE_LOCATION="${CACHE_DIR}/" \
FEX_ENABLECODECACHINGWIP=1 \
"${RUNNER_SCRIPT}" "${CANARY_BIN}" "${SEED}" >/dev/null
RC_SMOKE=$?
set -e

if [[ ${RC_SMOKE} -ne 0 ]]; then
  echo "FAIL: static cache runtime smoke failed with ${RC_SMOKE}" >&2
  exit 1
fi

echo "[5/5] Assertions"
echo "PASS: local AOT regressions completed (codemaps=${#CodeMaps[@]}, caches=${#Caches[@]}, seed=${SEED})"
