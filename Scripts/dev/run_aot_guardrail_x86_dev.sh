#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/Build-x86dev}"
RUNNER="${REPO_ROOT}/Scripts/dev/run_x86_dev.sh"
CANARY_SRC="${SCRIPT_DIR}/aot_canary.c"
CANARY_BIN="${BUILD_DIR}/Bin/aot_canary"
SEED="${SEED:-3735928559}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--seed <value>] [--keep-cache]

Runs a deterministic canary under:
  1) JIT mode (cache disabled)
  2) Cache mode warm-up run
  3) Cache mode validation run

Then checks output and exit-code parity between (1) and (3).

Environment overrides:
  BUILD_DIR, SEED, CC
EOF
}

KEEP_CACHE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed)
      SEED="${2:-}"
      if [[ -z "${SEED}" ]]; then
        echo "--seed requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --keep-cache)
      KEEP_CACHE=1
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

if [[ ! -x "${RUNNER}" ]]; then
  echo "Missing ${RUNNER}" >&2
  exit 1
fi

if [[ ! -x "${BUILD_DIR}/Bin/FEX" ]]; then
  echo "Missing ${BUILD_DIR}/Bin/FEX. Run Scripts/dev/setup_x86_dev.sh first." >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}/Bin"
CC_BIN="${CC:-cc}"
"${CC_BIN}" -O2 -std=c11 "${CANARY_SRC}" -o "${CANARY_BIN}"

CACHE_DIR="$(mktemp -d -t fex-aot-guardrail-XXXXXX)"
CACHE_DIR="${CACHE_DIR%/}/"
cleanup() {
  if [[ ${KEEP_CACHE} -eq 0 ]]; then
    rm -rf "${CACHE_DIR}"
  else
    echo "Kept cache directory: ${CACHE_DIR}"
  fi
}
trap cleanup EXIT

OUT_JIT="${CACHE_DIR}/jit.out"
OUT_CACHE_WARM="${CACHE_DIR}/cache-warm.out"
OUT_CACHE_VALIDATE="${CACHE_DIR}/cache-validate.out"

echo "[1/3] JIT baseline"
set +e
FEX_APP_CACHE_LOCATION="${CACHE_DIR}" \
FEX_ENABLECODECACHINGWIP=0 \
"${RUNNER}" "${CANARY_BIN}" "${SEED}" >"${OUT_JIT}" 2>&1
RC_JIT=$?
set -e

echo "[2/3] Cache warm-up"
set +e
FEX_APP_CACHE_LOCATION="${CACHE_DIR}" \
FEX_ENABLECODECACHINGWIP=1 \
"${RUNNER}" "${CANARY_BIN}" "${SEED}" >"${OUT_CACHE_WARM}" 2>&1
RC_CACHE_WARM=$?
set -e

echo "[3/3] Cache validation run"
set +e
FEX_APP_CACHE_LOCATION="${CACHE_DIR}" \
FEX_ENABLECODECACHINGWIP=1 \
"${RUNNER}" "${CANARY_BIN}" "${SEED}" >"${OUT_CACHE_VALIDATE}" 2>&1
RC_CACHE_VALIDATE=$?
set -e

if [[ ${RC_JIT} -ne ${RC_CACHE_VALIDATE} ]]; then
  echo "FAIL: exit code mismatch (jit=${RC_JIT}, cache=${RC_CACHE_VALIDATE})" >&2
  echo "JIT output: ${OUT_JIT}" >&2
  echo "Cache output: ${OUT_CACHE_VALIDATE}" >&2
  exit 1
fi

if ! diff -u "${OUT_JIT}" "${OUT_CACHE_VALIDATE}" >/dev/null; then
  echo "FAIL: output mismatch between JIT and cache run" >&2
  diff -u "${OUT_JIT}" "${OUT_CACHE_VALIDATE}" || true
  exit 1
fi

if [[ ${RC_CACHE_WARM} -ne 0 ]]; then
  echo "FAIL: cache warm-up run failed with ${RC_CACHE_WARM}" >&2
  exit 1
fi

echo "PASS: JIT and cache-enabled outputs match (seed=${SEED})"