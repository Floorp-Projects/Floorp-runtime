#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -e

# Arguments:
#   $1: platform (linux|mac|windows)
#   $2: arch (optional, for mac: x86_64|aarch64)
#   $3: pgo_artifact_name (optional)

PLATFORM="$1"
ARCH="$2"
PGO_ARTIFACT_NAME="$3"

echo "Setting up Rust for platform=$PLATFORM, arch=$ARCH, pgo_artifact=$PGO_ARTIFACT_NAME"

if [[ "$PLATFORM" == "windows" ]]; then
  if [[ -n "$PGO_ARTIFACT_NAME" ]]; then
    # for llvm 19
    # https://github.com/rust-lang/rust/commits/master/src/llvm-project
    # check here to match rust version with llvm
    rustup default 1.86.0
  fi
  rustup target add x86_64-pc-windows-msvc
elif [[ "$PLATFORM" == "linux" ]]; then
  if [[ "$ARCH" == "aarch64" ]]; then
    rustup default 1.86.0
    rustup target add aarch64-unknown-linux-gnu
  else
    rustup default 1.86.0
    rustup target add x86_64-unknown-linux-gnu
  fi
elif [[ "$PLATFORM" == "mac" ]]; then
  if [[ "$ARCH" == "x86_64" ]]; then
    TARGET="x86_64-apple-darwin"
  else
    TARGET="aarch64-apple-darwin"
  fi

  echo "Mac target: $TARGET"

  # Install and configure Rust toolchain for PGO builds
  if [[ -n "$PGO_ARTIFACT_NAME" ]]; then
    echo "PGO build detected - installing Rust 1.81.0"
    rustup toolchain install 1.81.0
    rustup default 1.81.0
    # Add target to the specific toolchain
    rustup target add "$TARGET" --toolchain 1.81.0

    # Verify target is installed for 1.81.0 toolchain
    echo "Verifying Rust target installation for 1.81.0:"
    rustup target list --toolchain 1.81.0 --installed | grep "$TARGET" || {
      echo "ERROR: Target $TARGET not found in 1.81.0 toolchain"
      echo "Attempting to add target again..."
      rustup target add "$TARGET" --toolchain 1.81.0
    }
  else
    echo "Non-PGO build - using stable toolchain"
    # Ensure we have stable toolchain
    rustup default stable
    # Add target to stable toolchain
    rustup target add "$TARGET"

    # Verify target is installed for stable toolchain
    echo "Verifying Rust target installation for stable:"
    rustup target list --installed | grep "$TARGET" || {
      echo "ERROR: Target $TARGET not found in stable toolchain"
      echo "Attempting to add target again..."
      rustup target add "$TARGET"
    }
  fi
fi

echo "Rust configuration complete:"
rustc --version --verbose
echo "Installed targets:"
rustup target list --installed

export CARGO_INCREMENTAL=0
