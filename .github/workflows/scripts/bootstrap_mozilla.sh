#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Bootstrap script for Mozilla build environment
# This script sets up the necessary dependencies and environment for building Mozilla/Firefox-based projects
#
# Usage: bootstrap_mozilla.sh [architecture]
#   architecture: x86_64, aarch64 (optional, defaults to x86_64)

set -e

ARCH="${1:-x86_64}"

echo "🔧 Bootstrapping Mozilla build environment for architecture: $ARCH"

# Function to detect the host architecture
detect_host_arch() {
    local host_arch
    host_arch=$(uname -m)
    case "$host_arch" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            echo "Unsupported architecture: $host_arch" >&2
            exit 1
            ;;
    esac
}

HOST_ARCH=$(detect_host_arch)
echo "📋 Host architecture detected: $HOST_ARCH"
echo "🎯 Target architecture: $ARCH"

# Cross-compilation setup if needed
if [[ "$HOST_ARCH" != "$ARCH" ]]; then
    echo "⚠️  Cross-compilation detected: $HOST_ARCH -> $ARCH"
    
    case "$ARCH" in
        aarch64)
            echo "🔄 Setting up aarch64 cross-compilation tools"
            sudo apt-get update
            sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
            export CC="aarch64-linux-gnu-gcc"
            export CXX="aarch64-linux-gnu-g++"
            export AR="aarch64-linux-gnu-ar"
            export STRIP="aarch64-linux-gnu-strip"
            ;;
        x86_64)
            if [[ "$HOST_ARCH" == "aarch64" ]]; then
                echo "🔄 Setting up x86_64 tools on aarch64"
                # This is less common but may be needed in some CI environments
                sudo apt-get update
                sudo apt-get install -y gcc-x86-64-linux-gnu g++-x86-64-linux-gnu
            fi
            ;;
    esac
fi

# Install base system dependencies
echo "📦 Installing base system dependencies"
sudo apt-get update
sudo apt-get install -y \
    curl \
    wget \
    git \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    autoconf2.13 \
    yasm \
    libgtk-3-dev \
    libgconf-2-dev \
    libxtst6 \
    libxrandr2 \
    libasound2-dev \
    libpango1.0-dev \
    libatk1.0-dev \
    libcairo-gobject2 \
    libgtk-3-dev \
    libgdk-pixbuf2.0-dev \
    libdbus-glib-1-dev \
    xvfb \
    mesa-utils

# Install Rust (required for Mozilla builds)
echo "🦀 Setting up Rust toolchain"
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Set up Rust target for cross-compilation if needed
if [[ "$HOST_ARCH" != "$ARCH" ]]; then
    case "$ARCH" in
        aarch64)
            rustup target add aarch64-unknown-linux-gnu
            ;;
        x86_64)
            rustup target add x86_64-unknown-linux-gnu
            ;;
    esac
fi

# Set up Python virtual environment
echo "🐍 Setting up Python virtual environment"
if [[ ! -d "$HOME/.mozvenv" ]]; then
    python3 -m venv "$HOME/.mozvenv"
fi
source "$HOME/.mozvenv/bin/activate"

# Install Python dependencies
pip install --upgrade pip
pip install setuptools wheel

# Bootstrap Mozilla build system
echo "🏗️  Bootstrapping Mozilla build system"
cd "$GITHUB_WORKSPACE" || exit 1

# Run mach bootstrap for browser builds
echo "Running mach bootstrap..."
python3 ./mach --no-interactive bootstrap --application-choice browser

# Additional setup for PGO builds
echo "🎯 Setting up PGO-specific tools"

# Ensure LLVM tools are available
if ! command -v llvm-profdata &> /dev/null; then
    echo "⚠️  llvm-profdata not found in PATH"
    
    # Try to find it in the Mozilla build environment
    MOZBUILD_PATH="$HOME/.mozbuild"
    if [[ -d "$MOZBUILD_PATH" ]]; then
        LLVM_TOOLS=$(find "$MOZBUILD_PATH" -name "llvm-profdata" -type f -executable 2>/dev/null | head -1)
        if [[ -n "$LLVM_TOOLS" ]]; then
            LLVM_DIR=$(dirname "$LLVM_TOOLS")
            echo "📍 Found LLVM tools in: $LLVM_DIR"
            echo "export PATH=\"$LLVM_DIR:\$PATH\"" >> "$HOME/.profile"
            export PATH="$LLVM_DIR:$PATH"
        fi
    fi
    
    # If still not found, install from system packages
    if ! command -v llvm-profdata &> /dev/null; then
        echo "📦 Installing LLVM tools from system packages"
        sudo apt-get install -y llvm
    fi
fi

# Verify tools are available
echo "🔍 Verifying build tools"
echo "Rust version: $(rustc --version)"
echo "Python version: $(python3 --version)"
if command -v llvm-profdata &> /dev/null; then
    echo "LLVM profdata: $(which llvm-profdata)"
else
    echo "⚠️  llvm-profdata still not available"
fi

# Set environment variables for the build
echo "🌍 Setting up environment variables"
cat >> "$HOME/.profile" << EOF
# Mozilla build environment
export MOZBUILD_STATE_PATH="\$HOME/.mozbuild"
export MOZILLA_ARCHIVE_HOST="https://archive.mozilla.org"

# PGO-specific environment
export LLVM_PROFDATA="\$(command -v llvm-profdata 2>/dev/null || echo 'llvm-profdata')"

# Architecture-specific settings
export MOZILLA_TARGET_ARCH="$ARCH"
EOF

source "$HOME/.profile"

echo "✅ Mozilla build environment bootstrap completed successfully!"
echo "🎯 Target architecture: $ARCH"
echo "💽 Host architecture: $HOST_ARCH"
echo "📁 Mozbuild path: $HOME/.mozbuild"

if [[ "$HOST_ARCH" != "$ARCH" ]]; then
    echo "🔄 Cross-compilation environment configured"
fi