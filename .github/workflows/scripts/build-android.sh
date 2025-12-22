#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -e

# Arguments:
#   $1: arch (arm64-v8a|armeabi-v7a|x86_64)
#   $2: MOZ_BUILD_DATE (optional)

ARCH="$1"
MOZ_BUILD_DATE="$2"

if [[ -n "$MOZ_BUILD_DATE" ]]; then
  export MOZ_BUILD_DATE="$MOZ_BUILD_DATE"
fi

# Map Android arch to target triple patterns for objdir discovery
case "$ARCH" in
  arm64-v8a)
    OBJDIR_PATTERNS=("obj-aarch64-unknown-linux-android" "obj-aarch64-linux-android" "obj-aarch64")
    ;;
  armeabi-v7a)
    OBJDIR_PATTERNS=("obj-arm-unknown-linux-androideabi" "obj-arm-linux-androideabi" "obj-armv7")
    ;;
  x86_64)
    OBJDIR_PATTERNS=("obj-x86_64-unknown-linux-android" "obj-x86_64-linux-android" "obj-x86_64")
    ;;
  *)
    echo "Unknown architecture: $ARCH"
    exit 1
    ;;
esac

echo "Building Android for arch: $ARCH"

# Set up Android SDK/NDK environment
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk-bundle}"

# Find NDK if not set
if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
  NDK_DIR=$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n1)
  if [[ -d "$NDK_DIR" ]]; then
    export ANDROID_NDK_HOME="$NDK_DIR"
  fi
fi

echo "ANDROID_HOME: $ANDROID_HOME"
echo "ANDROID_NDK_HOME: $ANDROID_NDK_HOME"

# Configure
export MOZ_NUM_JOBS=$(( $(nproc) * 3 / 4 ))
./mach configure

# Build
nice -n 10 ./mach build --jobs=$MOZ_NUM_JOBS

# Archive GeckoView
./mach android archive-geckoview

# Build GeckoView Example APK
./mach android build-geckoview_example

# Clean up cargo cache
rm -rf ~/.cargo

# Clean up build artifacts to free disk space for packaging
echo "Cleaning up build artifacts to free disk space..."
df -h

# Remove sccache cache
rm -rf ~/.cache/sccache

# Remove rustup toolchain caches
rm -rf ~/.rustup/toolchains/*/lib/rustlib/*/analysis

# Show disk space after cleanup
echo "Disk space after cleanup:"
df -h

# Artifact packaging
mkdir -p ~/output

# Find the object directory
OBJ_DIR=""
for pattern in "${OBJDIR_PATTERNS[@]}"; do
  if [[ -d "$pattern" ]]; then
    OBJ_DIR="$pattern"
    break
  fi
done

# Fallback: find any obj-* directory that looks like Android
if [[ -z "$OBJ_DIR" ]]; then
  OBJ_DIR=$(find . -maxdepth 1 -type d -name "obj-*android*" 2>/dev/null | head -1)
fi

if [[ -z "$OBJ_DIR" ]]; then
  echo "ERROR: Could not find object directory"
  ls -la obj-* 2>/dev/null || echo "No obj-* directories found"
  exit 1
fi

echo "Using object directory: $OBJ_DIR"

# Copy GeckoView AAR
# AAR files are located in gradle/maven (not gradle/build/maven)
GECKOVIEW_AAR=$(find "$OBJ_DIR/gradle/maven/org/mozilla/geckoview" -name "*.aar" 2>/dev/null | head -1)
if [[ -f "$GECKOVIEW_AAR" ]]; then
  cp "$GECKOVIEW_AAR" ~/output/floorp-geckoview-${ARCH}.aar
  echo "Copied GeckoView AAR: $GECKOVIEW_AAR"
else
  echo "ERROR: GeckoView AAR not found"
  echo "Searching for AAR files in object directory:"
  find "$OBJ_DIR" -name "*.aar" 2>/dev/null || true
  exit 1
fi

# Copy GeckoView Example APK
EXAMPLE_APK=$(find "$OBJ_DIR/gradle/build/mobile/android/geckoview_example/outputs/apk" -name "*.apk" 2>/dev/null | head -1)
if [[ -f "$EXAMPLE_APK" ]]; then
  cp "$EXAMPLE_APK" ~/output/floorp-geckoview-example-${ARCH}.apk
  echo "Copied GeckoView Example APK: $EXAMPLE_APK"
else
  echo "Warning: GeckoView Example APK not found"
fi

# Create maven archive
MAVEN_DIR="$OBJ_DIR/gradle/maven"
if [[ -d "$MAVEN_DIR" ]]; then
  (cd "$MAVEN_DIR" && zip -r ~/output/floorp-android-${ARCH}-maven.zip .)
  echo "Created Maven archive"
fi

# Create combined artifact archive
ARTIFACT_NAME="floorp-android-${ARCH}-moz-artifact"
(cd ~/output && zip -r "${ARTIFACT_NAME}.zip" . 2>/dev/null || true)

echo "Android build completed for $ARCH"
ls -la ~/output/

