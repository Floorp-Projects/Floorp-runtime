#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Build artifact management script for Mozilla-based projects
# This script handles the creation, validation, and packaging of build artifacts
#
# Usage: build_artifact.sh [platform] [architecture] [build_type] [output_dir]
#   platform: linux, windows, mac
#   architecture: x86_64, aarch64
#   build_type: debug, release, pgo-generate, pgo-use
#   output_dir: directory to store artifacts (optional, defaults to ~/output)

set -e

PLATFORM="${1:-linux}"
ARCH="${2:-x86_64}"
BUILD_TYPE="${3:-release}"
OUTPUT_DIR="${4:-$HOME/output}"

echo "🏗️  Building and packaging artifacts"
echo "📋 Platform: $PLATFORM"
echo "🎯 Architecture: $ARCH"
echo "🔨 Build type: $BUILD_TYPE"
echo "📁 Output directory: $OUTPUT_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to detect object directory based on platform and architecture
detect_objdir() {
    local platform="$1"
    local arch="$2"
    
    case "$platform" in
        linux)
            case "$arch" in
                x86_64)
                    echo "obj-x86_64-pc-linux-gnu"
                    ;;
                aarch64)
                    echo "obj-aarch64-unknown-linux-gnu"
                    ;;
                *)
                    echo "Unknown architecture for Linux: $arch" >&2
                    exit 1
                    ;;
            esac
            ;;
        windows)
            case "$arch" in
                x86_64)
                    echo "obj-x86_64-pc-windows-msvc"
                    ;;
                *)
                    echo "Unknown architecture for Windows: $arch" >&2
                    exit 1
                    ;;
            esac
            ;;
        mac)
            case "$arch" in
                x86_64)
                    echo "obj-x86_64-apple-darwin"
                    ;;
                aarch64|arm64)
                    echo "obj-aarch64-apple-darwin"
                    ;;
                *)
                    echo "Unknown architecture for macOS: $arch" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Unknown platform: $platform" >&2
            exit 1
            ;;
    esac
}

OBJDIR=$(detect_objdir "$PLATFORM" "$ARCH")
echo "📂 Object directory: $OBJDIR"

# Verify object directory exists
if [[ ! -d "$OBJDIR" ]]; then
    echo "❌ Object directory $OBJDIR does not exist!"
    echo "Available directories:"
    ls -la | grep "^d" | grep "obj-" || echo "No obj- directories found"
    exit 1
fi

# Function to get artifact extension
get_artifact_extension() {
    local platform="$1"
    case "$platform" in
        linux|mac)
            echo "tar.xz"
            ;;
        windows)
            echo "zip"
            ;;
        *)
            echo "Unknown platform: $platform" >&2
            exit 1
            ;;
    esac
}

ARTIFACT_EXT=$(get_artifact_extension "$PLATFORM")
ARTIFACT_NAME="floorp-${PLATFORM}-${ARCH}-moz-artifact.${ARTIFACT_EXT}"

echo "📦 Expected artifact name: $ARTIFACT_NAME"

# Find the built package
echo "🔍 Searching for built packages in $OBJDIR/dist/"
DIST_DIR="$OBJDIR/dist"

if [[ ! -d "$DIST_DIR" ]]; then
    echo "❌ Distribution directory $DIST_DIR does not exist!"
    exit 1
fi

# Find package files
case "$PLATFORM" in
    linux|mac)
        PACKAGE_FILES=($(find "$DIST_DIR" -name "floorp-*.tar.xz" 2>/dev/null || true))
        ;;
    windows)
        PACKAGE_FILES=($(find "$DIST_DIR" -name "floorp-*win64.zip" 2>/dev/null || true))
        ;;
esac

if [[ ${#PACKAGE_FILES[@]} -eq 0 ]]; then
    echo "❌ No package files found in $DIST_DIR"
    echo "Available files:"
    ls -la "$DIST_DIR" || true
    find "$DIST_DIR" -name "*floorp*" -o -name "*.tar.xz" -o -name "*.zip" 2>/dev/null || true
    exit 1
fi

if [[ ${#PACKAGE_FILES[@]} -gt 1 ]]; then
    echo "⚠️  Multiple package files found:"
    printf '%s\n' "${PACKAGE_FILES[@]}"
    echo "Using the first one: ${PACKAGE_FILES[0]}"
fi

PACKAGE_FILE="${PACKAGE_FILES[0]}"
echo "📦 Found package: $PACKAGE_FILE"

# Validate package file
if [[ ! -f "$PACKAGE_FILE" ]]; then
    echo "❌ Package file does not exist: $PACKAGE_FILE"
    exit 1
fi

# Get package size
PACKAGE_SIZE=$(stat -f%z "$PACKAGE_FILE" 2>/dev/null || stat -c%s "$PACKAGE_FILE" 2>/dev/null || echo "unknown")
echo "📊 Package size: $PACKAGE_SIZE bytes"

# Copy package to output directory
echo "📋 Copying package to output directory"
cp "$PACKAGE_FILE" "$OUTPUT_DIR/$ARTIFACT_NAME"

# Verify the copy
if [[ ! -f "$OUTPUT_DIR/$ARTIFACT_NAME" ]]; then
    echo "❌ Failed to copy package to output directory"
    exit 1
fi

OUTPUT_SIZE=$(stat -f%z "$OUTPUT_DIR/$ARTIFACT_NAME" 2>/dev/null || stat -c%s "$OUTPUT_DIR/$ARTIFACT_NAME" 2>/dev/null || echo "unknown")
echo "✅ Package copied successfully (size: $OUTPUT_SIZE bytes)"

# Copy application.ini for MAR (Mozilla Archive) updates
APP_INI_SRC="$OBJDIR/dist/bin/application.ini"
APP_INI_DEST="./nora-application.ini"

if [[ -f "$APP_INI_SRC" ]]; then
    echo "📝 Copying application.ini for MAR updates"
    cp "$APP_INI_SRC" "$APP_INI_DEST"
    echo "✅ application.ini copied to $APP_INI_DEST"
else
    echo "⚠️  application.ini not found at $APP_INI_SRC"
    # Try alternative locations
    ALT_LOCATIONS=(
        "$OBJDIR/dist/floorp/application.ini"
        "$OBJDIR/application.ini"
    )
    
    for alt_location in "${ALT_LOCATIONS[@]}"; do
        if [[ -f "$alt_location" ]]; then
            echo "📝 Found application.ini at alternative location: $alt_location"
            cp "$alt_location" "$APP_INI_DEST"
            echo "✅ application.ini copied from alternative location"
            break
        fi
    done
fi

# Generate artifact metadata
METADATA_FILE="$OUTPUT_DIR/${ARTIFACT_NAME}.metadata.json"
echo "📊 Generating artifact metadata"

cat > "$METADATA_FILE" << EOF
{
  "artifact_name": "$ARTIFACT_NAME",
  "platform": "$PLATFORM",
  "architecture": "$ARCH",
  "build_type": "$BUILD_TYPE",
  "package_size": $PACKAGE_SIZE,
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_package": "$(basename "$PACKAGE_FILE")",
  "object_directory": "$OBJDIR",
  "build_host": "$(uname -a)",
  "git_commit": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "git_branch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
}
EOF

echo "✅ Metadata generated: $METADATA_FILE"

# Validate artifact integrity
echo "🔍 Validating artifact integrity"
case "$ARTIFACT_EXT" in
    tar.xz)
        if command -v xz &> /dev/null; then
            if xz -t "$OUTPUT_DIR/$ARTIFACT_NAME"; then
                echo "✅ Artifact integrity verified (tar.xz)"
            else
                echo "❌ Artifact integrity check failed (tar.xz)"
                exit 1
            fi
        else
            echo "⚠️  xz command not available, skipping integrity check"
        fi
        ;;
    zip)
        if command -v unzip &> /dev/null; then
            if unzip -t "$OUTPUT_DIR/$ARTIFACT_NAME" >/dev/null 2>&1; then
                echo "✅ Artifact integrity verified (zip)"
            else
                echo "❌ Artifact integrity check failed (zip)"
                exit 1
            fi
        else
            echo "⚠️  unzip command not available, skipping integrity check"
        fi
        ;;
esac

# Summary
echo ""
echo "🎉 Artifact packaging completed successfully!"
echo "📁 Output directory: $OUTPUT_DIR"
echo "📦 Artifact: $ARTIFACT_NAME"
echo "📊 Size: $PACKAGE_SIZE bytes"
echo "📝 Metadata: $(basename "$METADATA_FILE")"
if [[ -f "$APP_INI_DEST" ]]; then
    echo "📄 Application config: $(basename "$APP_INI_DEST")"
fi
echo ""
echo "Generated files:"
ls -la "$OUTPUT_DIR"