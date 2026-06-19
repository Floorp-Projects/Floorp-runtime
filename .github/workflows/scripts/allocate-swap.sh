#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Allocate a swap file on the runner to provide additional virtual memory
# during the build. The size is chosen dynamically based on the free space
# available on the target filesystem so that a runner with a smaller disk
# (e.g. some aarch64 images) does not fail with "No space left on device".
set -uo pipefail

SWAP_FILE="/mnt/swapfile"
SWAP_MIN_GB=4      # minimum useful swap size
SWAP_MAX_GB=30     # upper cap (matches the previous fixed size)
SWAP_FREE_RATIO=90 # use at most 90% of the available space (in percent)

echo "Before:"
free -h
df -h

echo
echo

# Release any previously allocated swap file. These commands are expected to
# fail when no swap file exists yet (first run on a fresh runner), so their
# failures must not abort the script.
if sudo swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${SWAP_FILE}"; then
  sudo swapoff "${SWAP_FILE}" || true
fi
sudo rm -f "${SWAP_FILE}" || true

# Determine how much space is available (in GiB) on the filesystem that will
# hold the swap file. df outputs 1K-blocks; convert to GiB.
AVAIL_KB=$(df -P --output=avail "$(dirname "${SWAP_FILE}")" | tail -n 1 | tr -d ' ')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
TARGET_GB=$(( (AVAIL_GB * SWAP_FREE_RATIO) / 100 ))
if [ "${TARGET_GB}" -lt "${SWAP_MIN_GB}" ]; then
  echo "Warning: only ${AVAIL_GB}GiB free under $(dirname "${SWAP_FILE}"); using minimum ${SWAP_MIN_GB}GiB swap" >&2
  TARGET_GB="${SWAP_MIN_GB}"
fi
if [ "${TARGET_GB}" -gt "${SWAP_MAX_GB}" ]; then
  TARGET_GB="${SWAP_MAX_GB}"
fi

echo "Allocating ${TARGET_GB}GiB swap file at ${SWAP_FILE} (available: ${AVAIL_GB}GiB)"
sudo fallocate -l "${TARGET_GB}G" "${SWAP_FILE}"
sudo chmod 600 "${SWAP_FILE}"
sudo mkswap "${SWAP_FILE}"
sudo swapon "${SWAP_FILE}"

# APT operations with quiet flags
sudo apt autoremove -y -qq
sudo apt clean

# Optimized directory removal using rsync method
# Create empty directory for rsync deletion
mkdir -p /tmp/empty

# Function to safely remove directory using rsync
remove_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "Removing: $dir"
        sudo rsync -a --delete /tmp/empty/ "$dir/" 2>/dev/null
        sudo rmdir "$dir" 2>/dev/null
    fi
}

# Remove directories - using rsync method for large directories
remove_dir "./git"
remove_dir "/home/linuxbrew"
remove_dir "/usr/share/dotnet"
remove_dir "/usr/local/lib/android"
remove_dir "/usr/local/graalvm"
remove_dir "/usr/local/share/powershell"
remove_dir "/usr/local/share/chromium"
remove_dir "/opt/ghc"
remove_dir "/usr/local/share/boost"
remove_dir "/etc/apache2"
remove_dir "/etc/nginx"
remove_dir "/usr/local/share/chrome_driver"
remove_dir "/usr/local/share/edge_driver"
remove_dir "/usr/local/share/gecko_driver"
remove_dir "/usr/share/java"
remove_dir "/usr/share/miniconda"
remove_dir "/usr/local/share/vcpkg"

# Additional large directories
remove_dir "/opt/hostedtoolcache/CodeQL"
remove_dir "/usr/share/swift"
remove_dir "/opt/hostedtoolcache/go"
remove_dir "/opt/az"
remove_dir "/opt/microsoft"
remove_dir "/opt/hostedtoolcache/Ruby"
remove_dir "/opt/hostedtoolcache/Python"
remove_dir "/opt/hostedtoolcache/PyPy"
remove_dir "/usr/local/julia"
remove_dir "/usr/share/gradle"
remove_dir "/usr/share/apache-maven"
remove_dir "/usr/local/.ghcup"
remove_dir "/usr/local/aws-cli"
remove_dir "/usr/local/sqlpackage"
remove_dir "/usr/share/kotlinc"
remove_dir "/usr/share/sbt"
remove_dir "/usr/share/rust"
remove_dir "/usr/local/lib/node_modules"
remove_dir "/imagegeneration"
remove_dir "/opt/pipx"

# Remove Docker images to free up space
sudo docker image prune --all --force 2>/dev/null || true

# Cleanup
rmdir /tmp/empty 2>/dev/null

echo
echo

echo "After:"
free -h
df -h
