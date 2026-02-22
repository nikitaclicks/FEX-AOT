#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/Build-x86dev}"
INSTALL_PREFIX="${INSTALL_PREFIX:-${HOME}/.local/fex-x86dev}"
STATE_DIR="${STATE_DIR:-${HOME}/.cache/fex-x86dev}"
STATE_FILE="${STATE_DIR}/setup.env"

PACKAGES=(
  git
  cmake
  ninja-build
  clang
  lld
  llvm
  llvm-devel
  openssl-devel
  nasm
  python3-clang
  python3-setuptools
  squashfs-tools
  squashfuse
  erofs-fuse
  erofs-utils
  pkgconf-pkg-config
  ccache
  hyperfine
  qt6-qtdeclarative-devel
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--skip-deps] [--no-install] [--build-type <type>]

Options:
  --skip-deps         Skip installing Fedora dependencies with dnf
  --no-install        Build only (skip cmake install)
  --build-type TYPE   CMake build type (default: RelWithDebInfo)

Environment overrides:
  BUILD_DIR, INSTALL_PREFIX, STATE_DIR

Examples:
  $(basename "$0")
  $(basename "$0") --skip-deps --build-type Debug
EOF
}

SKIP_DEPS=0
DO_INSTALL=1
BUILD_TYPE="RelWithDebInfo"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-deps)
      SKIP_DEPS=1
      shift
      ;;
    --no-install)
      DO_INSTALL=0
      shift
      ;;
    --build-type)
      BUILD_TYPE="${2:-}"
      if [[ -z "${BUILD_TYPE}" ]]; then
        echo "--build-type requires a value" >&2
        exit 1
      fi
      shift 2
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

if [[ ${SKIP_DEPS} -eq 0 ]]; then
  echo "[1/5] Installing Fedora dependencies..."
  sudo dnf install -y "${PACKAGES[@]}"
else
  echo "[1/5] Skipping dependency installation"
fi

echo "[2/5] Updating git submodules..."
git -C "${REPO_ROOT}" submodule update --init --recursive

echo "[3/5] Configuring CMake build..."
if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]] && grep -Eq '^CMAKE_CXX_COMPILER:FILEPATH=.*/(g\+\+|c\+\+)$' "${BUILD_DIR}/CMakeCache.txt"; then
  echo "Detected stale GCC CMake cache; resetting ${BUILD_DIR}/CMakeCache.txt and CMakeFiles"
  rm -f "${BUILD_DIR}/CMakeCache.txt"
  rm -rf "${BUILD_DIR}/CMakeFiles"
fi

CC=clang CXX=clang++ cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DENABLE_X86_HOST_DEBUG=ON \
  -DENABLE_VIXL_SIMULATOR=ON \
  -DUSE_LINKER=lld \
  -DENABLE_LTO=ON \
  -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"

echo "[4/5] Building..."
cmake --build "${BUILD_DIR}" -j"$(nproc)"

if [[ ${DO_INSTALL} -eq 1 ]]; then
  echo "[5/5] Installing to ${INSTALL_PREFIX}..."
  cmake --install "${BUILD_DIR}"
else
  echo "[5/5] Skipping install"
fi

mkdir -p "${STATE_DIR}"
cat > "${STATE_FILE}" <<EOF
REPO_ROOT=${REPO_ROOT}
BUILD_DIR=${BUILD_DIR}
INSTALL_PREFIX=${INSTALL_PREFIX}
STATE_DIR=${STATE_DIR}
EOF

echo
echo "Setup finished."
echo "Try smoke tests (x86-host dev mode):"
echo "  ${REPO_ROOT}/Scripts/dev/run_x86_dev.sh /usr/bin/true"
echo "  ${REPO_ROOT}/Scripts/dev/run_x86_dev.sh /usr/bin/uname -a"
