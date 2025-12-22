#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# iOS GeckoTestBrowser build script for simulator
set -e

MOZ_BUILD_DATE="$1"

if [[ -n "$MOZ_BUILD_DATE" ]]; then
  export MOZ_BUILD_DATE="$MOZ_BUILD_DATE"
fi

echo "Building iOS GeckoTestBrowser for Simulator"

# Configure
export MOZ_NUM_JOBS=$(( $(sysctl -n hw.ncpu) * 3 / 4 ))
./mach configure

# Build Gecko core libraries
nice -n 10 ./mach build --jobs=$MOZ_NUM_JOBS

# Get the object directory
OBJ_DIR=$(./mach environment --format=json | python3 -c 'import sys, json; print(json.load(sys.stdin)["topobjdir"])')
echo "Object directory: $OBJ_DIR"

# Build GeckoTestBrowser.app using xcodebuild
XCODE_PROJECT="mobile/ios/GeckoTestBrowser/GeckoTestBrowser.xcodeproj"
SCHEME="GeckoTestBrowser"

export GECKO_TOPSRCDIR="$(pwd)"
export GECKO_TOPOBJDIR="$OBJ_DIR"

echo "Building GeckoTestBrowser with xcodebuild..."
xcodebuild \
  -project "$XCODE_PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath build/ios \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  GECKO_TOPSRCDIR="$GECKO_TOPSRCDIR" \
  GECKO_TOPOBJDIR="$GECKO_TOPOBJDIR" \
  build

# Clean up cargo cache
rm -rf ~/.cargo

# Artifact packaging
mkdir -p ~/output

# Find and copy the built .app
APP_PATH=$(find build/ios -name "GeckoTestBrowser.app" -type d 2>/dev/null | head -1)
if [[ -d "$APP_PATH" ]]; then
  echo "Found app at: $APP_PATH"
  
  # Zip the .app for artifact upload
  (cd "$(dirname "$APP_PATH")" && zip -r ~/output/floorp-ios-simulator-GeckoTestBrowser.zip "$(basename "$APP_PATH")")
  echo "Created iOS artifact: floorp-ios-simulator-GeckoTestBrowser.zip"
else
  echo "Warning: GeckoTestBrowser.app not found"
  find build/ios -name "*.app" -type d 2>/dev/null || echo "No .app files found"
fi

# Create combined artifact archive
ARTIFACT_NAME="floorp-ios-simulator-moz-artifact"
(cd ~/output && zip -r "${ARTIFACT_NAME}.zip" . 2>/dev/null || true)

echo "iOS build completed"
ls -la ~/output/
