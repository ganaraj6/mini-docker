#!/usr/bin/env bash
#
# setup_rootfs.sh
# Build a minimal root filesystem for the Mini Docker container runtime.
#
# This script copies a small set of host binaries into ./rootfs and
# recursively gathers every shared library those binaries need so they
# can run inside an isolated mount namespace.
#
# Usage:
#   ./setup_rootfs.sh
#
# The resulting tree is:
#   ./rootfs/{bin,lib,lib64,proc,sys,dev,etc,tmp}

set -euo pipefail

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${SCRIPT_DIR}/rootfs"

# Host binaries that should be available inside the container.
BINARIES=(
  /bin/bash
  /bin/ls
  /bin/ps
  /bin/echo
  /bin/cat
  /bin/pwd
  /bin/hostname
)

# Some distros place these under /usr/bin; fall back if /bin is a symlink
# that does not contain the file (or the file is missing).
resolve_binary() {
  local path="$1"
  if [[ -x "${path}" ]]; then
    echo "${path}"
    return 0
  fi

  local name
  name="$(basename "${path}")"
  if [[ -x "/usr/bin/${name}" ]]; then
    echo "/usr/bin/${name}"
    return 0
  fi

  echo "error: required binary not found: ${path}" >&2
  return 1
}

# Copy a file into the rootfs, preserving the absolute path layout.
# Example: /lib64/libc.so.6 -> ./rootfs/lib64/libc.so.6
copy_into_rootfs() {
  local src="$1"
  local dest="${ROOTFS}${src}"

  mkdir -p "$(dirname "${dest}")"

  # Skip if we already copied this exact path (shared deps across binaries).
  if [[ -e "${dest}" ]]; then
    return 0
  fi

  # Follow the real file (ldd often reports symlink paths).
  cp -aL "${src}" "${dest}"
}

# Parse ldd output and copy every resolved .so into the matching lib/lib64
# location under rootfs.
copy_shared_libs() {
  local binary="$1"
  local line lib_path

  # ldd prints lines like:
  #   libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x...)
  #   /lib64/ld-linux-x86-64.so.2 (0x...)
  #   linux-vdso.so.1 (0x...)   <- virtual, skip
  while IFS= read -r line; do
    lib_path=""

    if [[ "${line}" =~ =\>\ (/[^ ]+) ]]; then
      lib_path="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^[[:space:]]*(/[^ ]+) ]]; then
      lib_path="${BASH_REMATCH[1]}"
    fi

    # Ignore vdso and anything that is not a real file.
    if [[ -z "${lib_path}" ]] || [[ ! -e "${lib_path}" ]]; then
      continue
    fi

    copy_into_rootfs "${lib_path}"

    # Also place a copy under lib or lib64 when the host path is elsewhere
    # (e.g. /lib/x86_64-linux-gnu/libc.so.6) so a simple rpath/layout works.
    local base
    base="$(basename "${lib_path}")"
    if [[ "${lib_path}" == *"/lib64/"* ]] || [[ "${base}" == ld-linux-x86-64.so.2 ]]; then
      mkdir -p "${ROOTFS}/lib64"
      if [[ ! -e "${ROOTFS}/lib64/${base}" ]]; then
        cp -aL "${lib_path}" "${ROOTFS}/lib64/${base}"
      fi
    else
      mkdir -p "${ROOTFS}/lib"
      if [[ ! -e "${ROOTFS}/lib/${base}" ]]; then
        cp -aL "${lib_path}" "${ROOTFS}/lib/${base}"
      fi
    fi
  done < <(ldd "${binary}" 2>/dev/null || true)
}

echo "==> Creating rootfs directories under ${ROOTFS}"
mkdir -p \
  "${ROOTFS}/bin" \
  "${ROOTFS}/lib" \
  "${ROOTFS}/lib64" \
  "${ROOTFS}/proc" \
  "${ROOTFS}/sys" \
  "${ROOTFS}/dev" \
  "${ROOTFS}/etc" \
  "${ROOTFS}/tmp"

chmod 1777 "${ROOTFS}/tmp"

echo "==> Copying essential binaries"
for bin in "${BINARIES[@]}"; do
  src="$(resolve_binary "${bin}")"
  dest="${ROOTFS}/bin/$(basename "${src}")"
  cp -aL "${src}" "${dest}"
  chmod +x "${dest}"
  echo "    ${src} -> ${dest}"

  echo "==> Resolving shared libraries for $(basename "${src}")"
  copy_shared_libs "${src}"
done

# Dynamic linker must live at the path ELF binaries hard-code.
# On x86-64 GNU/Linux this is typically /lib64/ld-linux-x86-64.so.2
LD_LINUX="/lib64/ld-linux-x86-64.so.2"
if [[ ! -e "${LD_LINUX}" ]]; then
  # Common alternate locations
  for candidate in \
    /usr/lib64/ld-linux-x86-64.so.2 \
    /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
  do
    if [[ -e "${candidate}" ]]; then
      LD_LINUX="${candidate}"
      break
    fi
  done
fi

if [[ -e "${LD_LINUX}" ]]; then
  echo "==> Installing dynamic linker ${LD_LINUX}"
  mkdir -p "${ROOTFS}/lib64"
  cp -aL "${LD_LINUX}" "${ROOTFS}/lib64/ld-linux-x86-64.so.2"
else
  echo "warning: ld-linux-x86-64.so.2 not found on this host" >&2
fi

echo "==> Rootfs ready at ${ROOTFS}"
echo "    binaries: $(ls -1 "${ROOTFS}/bin" | tr '\n' ' ')"
echo "    lib:      $(find "${ROOTFS}/lib" -type f 2>/dev/null | wc -l) file(s)"
echo "    lib64:    $(find "${ROOTFS}/lib64" -type f 2>/dev/null | wc -l) file(s)"
