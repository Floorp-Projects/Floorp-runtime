#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Create GeckoView.xcframework from iOS build artifacts
set -e

OBJ_DIR="$1"
OUTPUT_DIR="${2:-~/output}"
ARCH="${3:-aarch64-apple-ios-sim}"

if [[ -z "$OBJ_DIR" ]]; then
    echo "Usage: $0 <obj-dir> [output-dir] [arch]"
    echo "Example: $0 obj-aarch64-apple-ios-sim ~/output"
    exit 1
fi

if [[ ! -d "$OBJ_DIR" ]]; then
    echo "Error: Object directory not found: $OBJ_DIR"
    exit 1
fi

echo "Creating GeckoView.xcframework from: $OBJ_DIR"
mkdir -p "$OUTPUT_DIR"

# Create temporary directory structure for XCFramework
WORK_DIR=$(mktemp -d)
FRAMEWORK_DIR="$WORK_DIR/GeckoView.framework"
mkdir -p "$FRAMEWORK_DIR"

# Determine platform based on architecture
case "$ARCH" in
    aarch64-apple-ios-sim|x86_64-apple-ios)
        PLATFORM="ios-arm64_x86_64-simulator"
        ;;
    aarch64-apple-ios)
        PLATFORM="ios-arm64"
        ;;
    *)
        echo "Warning: Unknown architecture $ARCH, defaulting to simulator"
        PLATFORM="ios-arm64_x86_64-simulator"
        ;;
esac

# Copy headers
echo "Copying headers..."
HEADER_SRC="$OBJ_DIR/dist/include/GeckoView"
if [[ -d "$HEADER_SRC" ]]; then
    mkdir -p "$FRAMEWORK_DIR/Headers"
    cp "$HEADER_SRC/"*.h "$FRAMEWORK_DIR/Headers/" 2>/dev/null || true
    echo "Copied headers from $HEADER_SRC"
else
    echo "Warning: Header directory not found: $HEADER_SRC"
fi

# Copy Swift wrapper sources for reference
SWIFT_SRC="$(dirname "$OBJ_DIR")/mobile/ios/GeckoTestBrowser/GeckoView"
if [[ -d "$SWIFT_SRC" ]]; then
    mkdir -p "$OUTPUT_DIR/GeckoViewSwift"
    cp "$SWIFT_SRC/"*.swift "$OUTPUT_DIR/GeckoViewSwift/" 2>/dev/null || true
    echo "Copied Swift wrapper sources to $OUTPUT_DIR/GeckoViewSwift"
fi

# Copy binary libraries
echo "Copying libraries..."
BIN_DIR="$OBJ_DIR/dist/bin"
if [[ -d "$BIN_DIR" ]]; then
    mkdir -p "$FRAMEWORK_DIR/Libraries"
    
    # Copy XUL (main Gecko library)
    if [[ -f "$BIN_DIR/XUL" ]]; then
        cp "$BIN_DIR/XUL" "$FRAMEWORK_DIR/Libraries/"
        echo "Copied XUL"
    fi
    
    # Copy all dylibs
    for dylib in "$BIN_DIR"/*.dylib; do
        if [[ -f "$dylib" ]]; then
            cp "$dylib" "$FRAMEWORK_DIR/Libraries/"
            echo "Copied $(basename "$dylib")"
        fi
    done
else
    echo "Error: Binary directory not found: $BIN_DIR"
    rm -rf "$WORK_DIR"
    exit 1
fi

# Create module.modulemap for Swift/Obj-C interop
cat > "$FRAMEWORK_DIR/Modules/module.modulemap" << 'EOF'
framework module GeckoView {
    umbrella header "GeckoView.h"
    
    export *
    module * { export * }
    
    link "GeckoView"
}
EOF
mkdir -p "$FRAMEWORK_DIR/Modules"
mv "$FRAMEWORK_DIR/Modules/module.modulemap" "$FRAMEWORK_DIR/Modules/module.modulemap" 2>/dev/null || true

# Create Info.plist
cat > "$FRAMEWORK_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>GeckoView</string>
    <key>CFBundleIdentifier</key>
    <string>org.nickersoft.geckoview</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GeckoView</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>15.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneSimulator</string>
        <string>iPhoneOS</string>
    </array>
</dict>
</plist>
EOF

# Create the XCFramework
echo "Creating XCFramework..."
XCFRAMEWORK_PATH="$OUTPUT_DIR/GeckoView.xcframework"
rm -rf "$XCFRAMEWORK_PATH"

# For now, create a simple framework bundle structure
# Full XCFramework with multiple platforms requires building for each target
mkdir -p "$XCFRAMEWORK_PATH/$PLATFORM/GeckoView.framework"
cp -R "$FRAMEWORK_DIR/"* "$XCFRAMEWORK_PATH/$PLATFORM/GeckoView.framework/"

# Create XCFramework Info.plist
cat > "$XCFRAMEWORK_PATH/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>$PLATFORM</string>
            <key>LibraryPath</key>
            <string>GeckoView.framework</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>ios</string>
            <key>SupportedPlatformVariant</key>
            <string>simulator</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

# Cleanup
rm -rf "$WORK_DIR"

echo ""
echo "=========================================="
echo "GeckoView.xcframework created successfully"
echo "Location: $XCFRAMEWORK_PATH"
echo ""
echo "Contents:"
ls -la "$XCFRAMEWORK_PATH"
echo ""
echo "Framework contents:"
ls -la "$XCFRAMEWORK_PATH/$PLATFORM/GeckoView.framework/"
echo "=========================================="

# Also create a zip archive for easier distribution
echo "Creating zip archive..."
(cd "$OUTPUT_DIR" && zip -r "GeckoView-xcframework.zip" "GeckoView.xcframework")
echo "Created: $OUTPUT_DIR/GeckoView-xcframework.zip"
