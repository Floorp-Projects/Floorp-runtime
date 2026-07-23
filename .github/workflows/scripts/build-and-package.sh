#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -eo pipefail

# Arguments:
#   $1: platform (linux|mac|windows)
#   $2: arch (x86_64|aarch64)
#   $3: MOZ_BUILD_DATE (required, 14 decimal digits)
#   $4: PGO mode (optional)

PLATFORM="${1:-}"
ARCH="${2:-}"
MOZ_BUILD_DATE="${3:-}"
PGO_MODE="${4:-}"

if [[ ! "$MOZ_BUILD_DATE" =~ ^[0-9]{14}$ ]]; then
  echo "MOZ_BUILD_DATE must be exactly 14 decimal digits (YYYYMMDDhhmmss)." >&2
  exit 1
fi
export MOZ_BUILD_DATE

export MOZ_NUM_JOBS=$(( $(nproc) * 3 / 4 ))
if [[ "$PLATFORM" == "linux" ]]; then
  sudo apt-get update -y
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

# Artifact packaging. The primary artifact is a consolidated bundle whose
# package remains at the artifact root for compatibility with existing users.
case "${PLATFORM}/${ARCH}" in
  windows/x86_64)
    OBJDIR="obj-x86_64-pc-windows-msvc"
    PACKAGE_EXTENSION="zip"
    ;;
  linux/x86_64)
    OBJDIR="obj-x86_64-pc-linux-gnu"
    PACKAGE_EXTENSION="tar.xz"
    ;;
  linux/aarch64)
    OBJDIR="obj-aarch64-unknown-linux-gnu"
    PACKAGE_EXTENSION="tar.xz"
    ;;
  mac/x86_64 | mac/aarch64)
    OBJDIR="obj-${ARCH}-apple-darwin"
    PACKAGE_EXTENSION="tar.gz"
    ;;
  *)
    echo "Unsupported platform/architecture combination: ${PLATFORM}/${ARCH}" >&2
    exit 1
    ;;
esac

# Exercise the built binary only when it is native to the Linux runner. Cross
# targets are verified later on their native downstream runners.
if [[ "$PLATFORM" == "linux" && "$ARCH" == "x86_64" && "$PGO_MODE" != "generate" ]]; then
  FULL_VERSION_BINARY="${OBJDIR}/dist/bin/floorp"
  if [[ ! -x "$FULL_VERSION_BINARY" ]]; then
    echo "Native --full-version probe is not executable: ${FULL_VERSION_BINARY}" >&2
    exit 1
  fi

  unset XUL_APP_FILE
  if FULL_VERSION_OUTPUT="$(timeout 30s "$FULL_VERSION_BINARY" --full-version 2>&1)"; then
    :
  else
    FULL_VERSION_STATUS=$?
    echo "Native --full-version probe failed with exit code ${FULL_VERSION_STATUS}." >&2
    printf '%s\n' "$FULL_VERSION_OUTPUT" >&2
    exit "$FULL_VERSION_STATUS"
  fi
  FULL_VERSION_PAIRS=()
  while IFS= read -r line; do
    read -r -a tokens <<< "$line"
    for ((i = 0; i + 1 < ${#tokens[@]}; i++)); do
      if [[ "${tokens[i]}" =~ ^[0-9]{14}$ && "${tokens[i + 1]}" =~ ^[0-9]{14}$ ]]; then
        FULL_VERSION_PAIRS+=("${tokens[i]} ${tokens[i + 1]}")
      fi
    done
  done <<< "$FULL_VERSION_OUTPUT"

  if (( ${#FULL_VERSION_PAIRS[@]} != 1 )); then
    echo "Expected exactly one adjacent application/platform BuildID pair from --full-version, found ${#FULL_VERSION_PAIRS[@]}." >&2
    printf '%s\n' "$FULL_VERSION_OUTPUT" >&2
    exit 1
  fi

  read -r APPLICATION_FULL_VERSION_ID PLATFORM_FULL_VERSION_ID <<< "${FULL_VERSION_PAIRS[0]}"
  if [[ "$APPLICATION_FULL_VERSION_ID" != "$MOZ_BUILD_DATE" || "$PLATFORM_FULL_VERSION_ID" != "$MOZ_BUILD_DATE" ]]; then
    echo "Native --full-version BuildIDs (${APPLICATION_FULL_VERSION_ID}, ${PLATFORM_FULL_VERSION_ID}) do not both match ${MOZ_BUILD_DATE}." >&2
    exit 1
  fi
  echo "Native --full-version BuildIDs match expected build ID: ${MOZ_BUILD_DATE}"
fi

: "${HOME:?HOME must be set}"
ARTIFACT_NAME="floorp-${PLATFORM}-${ARCH}-moz-artifact"
OUTPUT_ROOT="${HOME}/output"
BUNDLE_DIR="${OUTPUT_ROOT}/${ARTIFACT_NAME}-bundle"
PACKAGE_DEST="${BUNDLE_DIR}/${ARTIFACT_NAME}.${PACKAGE_EXTENSION}"
DIST_HOST_SRC="${OBJDIR}/dist/host"
DIST_HOST_DEST="${BUNDLE_DIR}/dist-host"

# Keep cleanup narrowly scoped to this build's staging directory.
case "$BUNDLE_DIR" in
  "${OUTPUT_ROOT}/"floorp-*-moz-artifact-bundle) ;;
  *)
    echo "Refusing to clean unexpected bundle path: ${BUNDLE_DIR}" >&2
    exit 1
    ;;
esac
rm -rf -- "$BUNDLE_DIR"
mkdir -p "$DIST_HOST_DEST"

shopt -s nullglob
if [[ "$PLATFORM" == "windows" ]]; then
  PACKAGE_MATCHES=("${OBJDIR}"/dist/floorp-*win64.zip)
  if (( ${#PACKAGE_MATCHES[@]} != 1 )); then
    echo "Expected exactly one Windows package, found ${#PACKAGE_MATCHES[@]}." >&2
    printf '  %s\n' "${PACKAGE_MATCHES[@]}" >&2
    exit 1
  fi
  mv -- "${PACKAGE_MATCHES[0]}" "$PACKAGE_DEST"
elif [[ "$PLATFORM" == "linux" ]]; then
  PACKAGE_MATCHES=("${OBJDIR}"/dist/floorp-*.tar.xz)
  if (( ${#PACKAGE_MATCHES[@]} != 1 )); then
    echo "Expected exactly one Linux package, found ${#PACKAGE_MATCHES[@]}." >&2
    printf '  %s\n' "${PACKAGE_MATCHES[@]}" >&2
    exit 1
  fi
  mv -- "${PACKAGE_MATCHES[0]}" "$PACKAGE_DEST"
else
  if [[ "$PGO_MODE" == "generate" ]]; then
    tar -czf "$PACKAGE_DEST" "./${OBJDIR}/"
  else
    tar -czf "$PACKAGE_DEST" -C "./${OBJDIR}/dist" .
  fi
fi

if [[ ! -s "$PACKAGE_DEST" ]]; then
  echo "Primary package is missing or empty: ${PACKAGE_DEST}" >&2
  exit 1
fi

if [[ ! -d "$DIST_HOST_SRC" ]]; then
  echo "Required dist/host directory is missing: ${DIST_HOST_SRC}" >&2
  exit 1
fi
if [[ -z "$(find "$DIST_HOST_SRC" -mindepth 1 -print -quit)" ]]; then
  echo "Required dist/host directory is empty: ${DIST_HOST_SRC}" >&2
  exit 1
fi
cp -a "$DIST_HOST_SRC"/. "$DIST_HOST_DEST"/

APPLICATION_INI_SRC="${OBJDIR}/dist/bin/application.ini"
if [[ ! -f "$APPLICATION_INI_SRC" ]]; then
  APPLICATION_INI_MATCHES=()
  while IFS= read -r -d '' candidate; do
    APPLICATION_INI_MATCHES+=("$candidate")
  done < <(find "${OBJDIR}/dist" -type f -path '*/Contents/Resources/application.ini' -print0)

  if (( ${#APPLICATION_INI_MATCHES[@]} != 1 )); then
    echo "Expected exactly one packaged application.ini, found ${#APPLICATION_INI_MATCHES[@]}." >&2
    printf '  %s\n' "${APPLICATION_INI_MATCHES[@]}" >&2
    exit 1
  fi
  APPLICATION_INI_SRC="${APPLICATION_INI_MATCHES[0]}"
fi

APPLICATION_BUILD_ID="$(sed -n 's/^BuildID=//p' "$APPLICATION_INI_SRC" | head -n 1 | tr -d '\r')"
if [[ ! "$APPLICATION_BUILD_ID" =~ ^[0-9]{14}$ ]]; then
  echo "Diagnostic application.ini has an invalid BuildID: ${APPLICATION_INI_SRC}" >&2
  exit 1
fi
if [[ "$APPLICATION_BUILD_ID" != "$MOZ_BUILD_DATE" ]]; then
  echo "Diagnostic application.ini BuildID (${APPLICATION_BUILD_ID}) does not match expected build ID (${MOZ_BUILD_DATE})." >&2
  exit 1
fi
cp -- "$APPLICATION_INI_SRC" "${BUNDLE_DIR}/floorp-application.ini"

echo "Staged consolidated artifact bundle: ${BUNDLE_DIR}"
echo "Diagnostic application.ini BuildID matches expected build ID: ${MOZ_BUILD_DATE}"
