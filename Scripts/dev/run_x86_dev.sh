#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/Build-x86dev}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <program> [args...]" >&2
  echo "Example: $(basename "$0") /usr/bin/uname -a" >&2
  exit 1
fi

if [[ ! -x "${BUILD_DIR}/Bin/FEX" ]]; then
  echo "Missing ${BUILD_DIR}/Bin/FEX. Run Scripts/dev/setup_x86_dev.sh first." >&2
  exit 1
fi

# On x86-host dev builds, this profile avoids simulator faults.
export FEX_TSOENABLED="${FEX_TSOENABLED:-0}"
export FEX_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS="${FEX_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS:-0}"

exec "${BUILD_DIR}/Bin/FEX" "$@"
