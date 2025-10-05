#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -e

# Arguments:
#   $1: platform (linux|mac|windows)
#   $2: arch (x86_64|aarch64)
#   $3: debug (true|false)
#   $4: pgo (true|false)
#   $5: pgo_mode ("generate"|"use")
#   $6: pgo_artifact_name (string, for "use" mode)
#   $7: MOZ_BUILD_DATE (optional)

PLATFORM="$1"
ARCH="$2"
DEBUG="$3"
PGO="$4"
PGO_MODE="$5"
PGO_ARTIFACT_NAME="$6"
MOZ_BUILD_DATE="$7"

if [[ -n "$MOZ_BUILD_DATE" ]]; then
  export MOZ_BUILD_DATE="$MOZ_BUILD_DATE"
fi

cd "$GITHUB_WORKSPACE"

if [[ "$PLATFORM" == "windows" ]]; then
  cp ./.github/workflows/mozconfigs/windows-x86_64.mozconfig mozconfig
elif [[ "$PLATFORM" == "linux" ]]; then
  if [[ "$ARCH" == "aarch64" ]]; then
    cp ./.github/workflows/mozconfigs/linux-aarch64.mozconfig mozconfig
  else
    cp ./.github/workflows/mozconfigs/linux-x86_64.mozconfig mozconfig
  fi
elif [[ "$PLATFORM" == "mac" ]]; then
  if [[ "$ARCH" == "x86_64" ]]; then
    cp ./.github/workflows/mozconfigs/macosx64-x86_64.mozconfig mozconfig
  else
    cp ./.github/workflows/mozconfigs/macosx64-aarch64.mozconfig mozconfig
  fi
  
  # Add macOS SDK path for cross-compilation
  echo "ac_add_options --with-macos-sdk=$(echo ~)/macos-sdk" >> mozconfig
fi

# Copy branding assets
if [[ -d ".github/assets/branding" ]]; then
  cp -r ./.github/assets/branding/* ./browser/branding/
  
  if [[ "$PLATFORM" == "mac" ]]; then
    # Set Branding for Mac
    echo "ac_add_options --with-branding=browser/branding/floorp-official" >> mozconfig
    # Set Flat Chrome (skip for profile generation)
    if [[ "$PGO_MODE" != "generate" ]]; then
      echo "ac_add_options --enable-chrome-format=flat" >> mozconfig
    fi
  else
    # Set Branding for Linux/Windows
    echo "ac_add_options --with-branding=browser/branding/floorp-daylight" >> mozconfig
    echo "ac_add_options --enable-chrome-format=flat" >> mozconfig
  fi
else
  echo "No custom branding found, using default Firefox branding"
fi

# Enable Linker for Mac
if [[ "$PLATFORM" == "mac" ]]; then
  echo "ac_add_options --enable-linker=lld" >> mozconfig
fi

sudo apt install msitools -y

# SCCACHE
{
  echo "mk_add_options 'export RUSTC_WRAPPER=/opt/hostedtoolcache/sccache/0.10.0/x64/sccache'"
  echo "mk_add_options 'export CCACHE_CPP2=yes'"
  echo "ac_add_options --with-ccache=/opt/hostedtoolcache/sccache/0.10.0/x64/sccache"
  echo "mk_add_options 'export SCCACHE_GHA_ENABLED=on'"
} >> mozconfig


# Debug
if [[ "$DEBUG" == "true" ]]; then
  echo "ac_add_options --enable-debug" >> mozconfig
fi

# PGO
if [[ "$PGO" == "true" ]]; then
  if [[ "$PGO_MODE" == "generate" ]]; then
    # Use profile-generate for cross-platform builds
    echo 'ac_add_options --enable-profile-generate=cross' >> mozconfig
  elif [[ "$PGO_MODE" == "use" && -n "$PGO_ARTIFACT_NAME" ]]; then
    # Use a downloaded profile by its artifact name
    echo 'export MOZ_LTO=cross' >> mozconfig
    echo 'ac_add_options --enable-profile-use=cross' >> mozconfig
    echo 'ac_add_options --with-pgo-profile-path=$(echo ~)/artifacts/merged.profdata' >> mozconfig
    echo 'ac_add_options --with-pgo-jarlog=$(echo ~)/artifacts/en-US.log' >> mozconfig
  fi
fi

# Update Channel
if [[ "$PLATFORM" == "mac" ]]; then
  echo "ac_add_options --enable-update-channel=release" >> mozconfig
  echo "ac_add_options --with-version-file-path=floorp/gecko/config" >> mozconfig
  sed -i 's|https://@MOZ_APPUPDATE_HOST@/update/6/%PRODUCT%/%VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION%/%SYSTEM_CAPABILITIES%/%DISTRIBUTION%/%DISTRIBUTION_VERSION%/update.xml|https://%NORA_UPDATE_HOST%update.xml|g' ./build/application.ini.in
else
  echo "ac_add_options --enable-update-channel=alpha" >> mozconfig
  sed -i 's|https://@MOZ_APPUPDATE_HOST@/update/6/%PRODUCT%/%VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION%/%SYSTEM_CAPABILITIES%/%DISTRIBUTION%/%DISTRIBUTION_VERSION%/update.xml|https://github.com/f3liz-dev/Floorp-runtime/releases/download/%CHANNEL%/%BUILD_TARGET%.update.xml|g' ./build/application.ini.in
fi

./mach --no-interactive bootstrap --application-choice browser
