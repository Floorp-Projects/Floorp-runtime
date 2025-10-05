#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -e

# Arguments:
#   $1: arch (x86_64|aarch64)

ARCH="$1"

echo "Setting up macOS cross-compilation environment for $ARCH"

# Download macOS SDK artifact
echo "Downloading macOS SDK..."
# This will be handled by the workflow's download-artifact step

# Extract macOS SDK
echo "Extracting macOS SDK..."
mkdir -p ~/macos-sdk
tar -xzf ~/macos-sdk-artifact/macos_sdk.tar.gz -C ~/macos-sdk --warning=no-unknown-keyword

# Install LLVM toolchain
echo "Installing LLVM 19 toolchain for cross-compilation..."
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 19
sudo apt-get install -y lld-19

# Create symlinks for the tools
sudo ln -sf /usr/bin/ld.lld-19 /usr/bin/ld64.lld
sudo ln -sf /usr/bin/clang-19 /usr/bin/clang
sudo ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Verify versions
echo "Checking installed versions:"
clang --version
ld64.lld --version || ld.lld-19 --version

echo "macOS cross-compilation setup complete"