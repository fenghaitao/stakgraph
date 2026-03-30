#!/usr/bin/env bash
# Point Cargo and dynamic loaders at OpenSSL built under .deps/openssl-install.
# If that install is missing or incomplete, downloads OpenSSL source, builds, and installs it there.
#
# Optional environment (before sourcing or invoking):
#   OPENSSL_VERSION=3.4.1           # source release to fetch
#   OPENSSL_CONFIGURE_TARGET=...    # override if auto-detect fails (see OpenSSL INSTALL.md)
#
#   source scripts/local-openssl-env.sh
#       Export OPENSSL_DIR, PKG_CONFIG_PATH, LD_LIBRARY_PATH in the current shell.
#
#   scripts/local-openssl-env.sh cargo build
#   scripts/local-openssl-env.sh cargo test -p ast
#       Run a single command with that environment.
#
# Repo root (where .deps/ is created) is resolved as:
#   1. STAKGRAPH_ROOT if set
#   2. Parent of this file's directory if that directory is named "scripts"
#   3. Nearest ancestor of this file that contains both Cargo.toml and ast/Cargo.toml
#   If none match, set STAKGRAPH_ROOT explicitly.

set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.4.1}"
# Official release tarball (openssl.org redirects here).
OPENSSL_TARBALL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

resolve_repo_root() {
  if [[ -n "${STAKGRAPH_ROOT:-}" ]]; then
    echo "$(cd "$STAKGRAPH_ROOT" && pwd)"
    return 0
  fi
  if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
    echo "$(cd "$SCRIPT_DIR/.." && pwd)"
    return 0
  fi
  local cur="$SCRIPT_DIR"
  while [[ "$cur" != "/" ]]; do
    if [[ -f "$cur/Cargo.toml" && -f "$cur/ast/Cargo.toml" ]]; then
      echo "$(cd "$cur" && pwd)"
      return 0
    fi
    cur="$(dirname "$cur")"
  done
  echo "error: cannot find stakgraph repo root. Put this script in .../scripts/, place it under the repo tree, or set STAKGRAPH_ROOT to the repository root." >&2
  return 1
}

REPO_ROOT="$(resolve_repo_root)" || exit 1
DEPS_DIR="$REPO_ROOT/.deps"
OPENSSL_INSTALL="$DEPS_DIR/openssl-install"
OPENSSL_SRC_DIR="$DEPS_DIR/openssl-${OPENSSL_VERSION}"
OPENSSL_SSLDIR="$DEPS_DIR/openssl-ssl"

deps_have_openssl() {
  [[ -d "$OPENSSL_INSTALL/include/openssl" ]] || return 1
  if [[ -d "$OPENSSL_INSTALL/lib64" ]]; then
    local lib="$OPENSSL_INSTALL/lib64"
  elif [[ -d "$OPENSSL_INSTALL/lib" ]]; then
    local lib="$OPENSSL_INSTALL/lib"
  else
    return 1
  fi
  [[ -e "$lib/pkgconfig/openssl.pc" || -e "$lib/pkgconfig/libssl.pc" ]] || return 1
  [[ -e "$lib/libssl.so" || -e "$lib/libssl.dylib" || -e "$lib/libssl.a" ]] || return 1
  return 0
}

openssl_configure_target() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)  echo linux-x86_64 ;;
    Linux/aarch64) echo linux-aarch64 ;;
    Darwin/x86_64) echo darwin64-x86_64 ;;
    Darwin/arm64)  echo darwin64-arm64 ;;
    *)
      echo "error: unsupported platform $(uname -s)/$(uname -m); set OPENSSL_CONFIGURE_TARGET manually" >&2
      return 1
      ;;
  esac
}

ensure_openssl_built() {
  if deps_have_openssl; then
    return 0
  fi

  for cmd in curl tar make gcc perl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "error: '$cmd' is required to build OpenSSL but was not found in PATH" >&2
      exit 1
    fi
  done

  local configure_target="${OPENSSL_CONFIGURE_TARGET:-}"
  if [[ -z "$configure_target" ]]; then
    configure_target="$(openssl_configure_target)" || exit 1
  fi

  mkdir -p "$DEPS_DIR"
  local tarball="$DEPS_DIR/openssl-${OPENSSL_VERSION}.tar.gz"

  if [[ ! -d "$OPENSSL_SRC_DIR" ]]; then
    if [[ ! -f "$tarball" ]]; then
      echo "Downloading OpenSSL ${OPENSSL_VERSION}..." >&2
      curl -fL --retry 3 --retry-delay 2 -o "$tarball" "$OPENSSL_TARBALL_URL"
    fi
    echo "Extracting OpenSSL ${OPENSSL_VERSION}..." >&2
    tar -xzf "$tarball" -C "$DEPS_DIR"
  fi

  echo "Configuring OpenSSL (${configure_target}) -> $OPENSSL_INSTALL ..." >&2
  (
    cd "$OPENSSL_SRC_DIR"
    ./Configure "$configure_target" \
      --prefix="$OPENSSL_INSTALL" \
      --openssldir="$OPENSSL_SSLDIR" \
      shared
  )

  local jobs
  jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  echo "Building OpenSSL (-j${jobs})..." >&2
  make -C "$OPENSSL_SRC_DIR" -j"$jobs"

  echo "Installing OpenSSL (software only)..." >&2
  make -C "$OPENSSL_SRC_DIR" install_sw

  if ! deps_have_openssl; then
    echo "error: OpenSSL install at $OPENSSL_INSTALL still looks incomplete after build" >&2
    exit 1
  fi
  echo "OpenSSL ${OPENSSL_VERSION} ready at $OPENSSL_INSTALL" >&2
}

ensure_openssl_built

if [[ -d "$OPENSSL_INSTALL/lib64" ]]; then
  LIB_DIR="$OPENSSL_INSTALL/lib64"
elif [[ -d "$OPENSSL_INSTALL/lib" ]]; then
  LIB_DIR="$OPENSSL_INSTALL/lib"
else
  echo "error: no lib or lib64 under $OPENSSL_INSTALL" >&2
  exit 1
fi

export OPENSSL_DIR="$OPENSSL_INSTALL"
export PKG_CONFIG_PATH="$LIB_DIR/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -eq 0 ]]; then
    echo "usage:" >&2
    echo "  source $0                 # export vars in current bash shell" >&2
    echo "  $0 <command> [args...]    # run one command (e.g. cargo build)" >&2
    exit 2
  fi
  exec "$@"
fi
