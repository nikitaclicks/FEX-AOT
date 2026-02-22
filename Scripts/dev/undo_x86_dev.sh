#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_BUILD_DIR="${REPO_ROOT}/Build-x86dev"
DEFAULT_INSTALL_PREFIX="${HOME}/.local/fex-x86dev"
DEFAULT_STATE_DIR="${HOME}/.cache/fex-x86dev"
STATE_FILE="${DEFAULT_STATE_DIR}/setup.env"

PACKAGES=(
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
  qt6-qtdeclarative-devel
)

if [[ -f "${STATE_FILE}" ]]; then
  source "${STATE_FILE}"
fi

BUILD_DIR="${BUILD_DIR:-${DEFAULT_BUILD_DIR}}"
INSTALL_PREFIX="${INSTALL_PREFIX:-${DEFAULT_INSTALL_PREFIX}}"
STATE_DIR="${STATE_DIR:-${DEFAULT_STATE_DIR}}"

PURGE_DEPS=0
REMOVE_CCACHE=0
YES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--purge-system-deps] [--remove-ccache] [--yes]

Options:
  --purge-system-deps  Also remove setup-installed dnf packages (uses sudo)
  --remove-ccache      Also remove ~/.cache/ccache
  --yes                Skip interactive confirmation
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-system-deps)
      PURGE_DEPS=1
      shift
      ;;
    --remove-ccache)
      REMOVE_CCACHE=1
      shift
      ;;
    --yes)
      YES=1
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

echo "Cleanup targets:"
echo "  Build dir:      ${BUILD_DIR}"
echo "  Install prefix: ${INSTALL_PREFIX}"
echo "  State dir:      ${STATE_DIR}"
[[ -d "${BUILD_DIR}" ]] && du -sh "${BUILD_DIR}" || true
[[ -d "${INSTALL_PREFIX}" ]] && du -sh "${INSTALL_PREFIX}" || true
[[ -d "${STATE_DIR}" ]] && du -sh "${STATE_DIR}" || true

if [[ ${REMOVE_CCACHE} -eq 1 && -d "${HOME}/.cache/ccache" ]]; then
  echo "  ccache dir:     ${HOME}/.cache/ccache"
  du -sh "${HOME}/.cache/ccache" || true
fi

if [[ ${YES} -ne 1 ]]; then
  read -r -p "Proceed with cleanup? [y/N] " answer
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Removing local artifacts..."
rm -rf -- "${BUILD_DIR}" "${INSTALL_PREFIX}" "${STATE_DIR}"

if [[ ${REMOVE_CCACHE} -eq 1 ]]; then
  rm -rf -- "${HOME}/.cache/ccache"
fi

if [[ ${PURGE_DEPS} -eq 1 ]]; then
  echo "Removing Fedora packages installed for this setup..."
  sudo dnf remove -y "${PACKAGES[@]}"
fi

echo "Cleanup complete."
