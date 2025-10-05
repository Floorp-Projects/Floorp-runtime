# SPDX-License-Identifier: MPL-2.0

echo "Before:"
free -h
df -h

echo
echo

sudo swapoff /mnt/swapfile
sudo rm /mnt/swapfile
sudo fallocate -l 30G /mnt/swapfile
sudo chmod 600 /mnt/swapfile
sudo mkswap /mnt/swapfile
sudo swapon /mnt/swapfile

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

# Cleanup
rmdir /tmp/empty 2>/dev/null

echo
echo

echo "After:"
free -h
df -h
