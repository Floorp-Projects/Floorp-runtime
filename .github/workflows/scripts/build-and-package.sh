#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -e

# Arguments:
#   $1: platform (linux|mac|windows)
#   $2: arch (x86_64|aarch64)
#   $3: MOZ_BUILD_DATE (optional)

PLATFORM="$1"
ARCH="$2"
MOZ_BUILD_DATE="$3"

if [[ -n "$MOZ_BUILD_DATE" ]]; then
  export MOZ_BUILD_DATE="$MOZ_BUILD_DATE"
fi

export MOZ_NUM_JOBS=$(( $(nproc) * 3 / 4 ))
if [[ "$PLATFORM" == "linux" ]]; then
  sudo apt-get install -y xvfb mesa-utils
  export LIBGL_ALWAYS_SOFTWARE=1
  xvfb-run -a -s "-screen 0 1024x768x24" ./mach configure
  xvfb-run -a -s "-screen 0 1024x768x24" nice -n 10 ./mach build --jobs=$MOZ_NUM_JOBS
  xvfb-run -a -s "-screen 0 1024x768x24" ./mach package
elif [[ "$PLATFORM" == "mac" ]]; then
  echo "Build environment:"
  echo "CC=$CC"
  echo "CXX=$CXX"
  echo "LD=$LD"
  echo "AR=$AR"
  echo "NM=$NM"
  echo "RANLIB=$RANLIB"
  echo "STRIP=$STRIP"
  echo "OBJCOPY=$OBJCOPY"
  echo "OBJDUMP=$OBJDUMP"
  echo "READELF=$READELF"
  echo "PKG_CONFIG=$PKG_CONFIG"
  echo "PYTHON=$PYTHON"
  echo "RUSTC=$RUSTC"
  echo "CARGO=$CARGO"
  
  ./mach configure
  nice -n 10 ./mach build --jobs=$MOZ_NUM_JOBS
  ./mach package
else
  ./mach configure
  nice -n 10 ./mach build --jobs=$MOZ_NUM_JOBS
  ./mach package
fi
rm -rf ~/.cargo

# Artifact packaging
mkdir -p ~/output

ARTIFACT_NAME="floorp-${PLATFORM}-${ARCH}-moz-artifact"
if [[ "$PLATFORM" == "windows" ]]; then
  mv obj-x86_64-pc-windows-msvc/dist/floorp-*win64.zip ~/output/${ARTIFACT_NAME}.zip
  cp ./obj-x86_64-pc-windows-msvc/dist/bin/application.ini ./floorp-application.ini || true
elif [[ "$PLATFORM" == "linux" ]]; then
  if [[ "$ARCH" == "aarch64" ]]; then
    mv obj-aarch64-unknown-linux-gnu/dist/floorp-*.tar.xz ~/output/${ARTIFACT_NAME}.tar.xz
    cp ./obj-aarch64-unknown-linux-gnu/dist/bin/application.ini ./floorp-application.ini || true
  else
    mv obj-x86_64-pc-linux-gnu/dist/floorp-*.tar.xz ~/output/${ARTIFACT_NAME}.tar.xz
    cp obj-x86_64-pc-linux-gnu/dist/bin/application.ini ./floorp-application.ini || true
  fi
elif [[ "$PLATFORM" == "mac" ]]; then
  # Mac-specific packaging
  if [[ "$ARCH" == "aarch64" ]]; then
    tar -czf floorp-${ARCH}-apple-darwin-with-pgo.tar.gz ./obj-${ARCH}-apple-darwin/
    mv floorp-${ARCH}-apple-darwin-with-pgo.tar.gz ~/output/${ARTIFACT_NAME}.tar.gz
  else
    tar -czf floorp-${ARCH}-apple-darwin-with-pgo.tar.gz ./obj-${ARCH}-apple-darwin/
    mv floorp-${ARCH}-apple-darwin-with-pgo.tar.gz ~/output/${ARTIFACT_NAME}.tar.gz
  fi
fi

# Stage dist-host directory with a stable root for downstream workflows.
DIST_HOST_DEST="$HOME/output/${PLATFORM}-${ARCH}-dist-host"
rm -rf "$DIST_HOST_DEST"
mkdir -p "$DIST_HOST_DEST"

if [[ "$PLATFORM" == "windows" ]]; then
  DIST_HOST_SRC="obj-x86_64-pc-windows-msvc/dist/host"
elif [[ "$PLATFORM" == "linux" ]]; then
  if [[ "$ARCH" == "aarch64" ]]; then
    DIST_HOST_SRC="obj-aarch64-unknown-linux-gnu/dist/host"
  else
    DIST_HOST_SRC="obj-x86_64-pc-linux-gnu/dist/host"
  fi
elif [[ "$PLATFORM" == "mac" ]]; then
  DIST_HOST_SRC="obj-${ARCH}-apple-darwin/dist/host"
else
  DIST_HOST_SRC=""
fi

if [[ -n "$DIST_HOST_SRC" && -d "$DIST_HOST_SRC" ]]; then
  cp -a "$DIST_HOST_SRC"/. "$DIST_HOST_DEST"/
else
  echo "Warning: dist/host directory not found for ${PLATFORM}-${ARCH} (expected ${DIST_HOST_SRC})" >&2
fi
