#!/bin/bash

# Require sudo permission
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo." 
   exit 1
fi

# Detect the actual user
ACTUAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# Get the directory where this script is located
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "Running setup for system and user: $ACTUAL_USER"
echo "Script directory: $SCRIPT_DIR"

install_local_font() {
    local folder_name=$1
    local dest_name=$2
    local source_path="$SCRIPT_DIR/fonts/$folder_name"
    local dest_path="/usr/local/share/fonts/$dest_name"

    if [ ! -d "$source_path" ]; then
        echo "Warning: Local font directory not found: $source_path"
        return
    fi

    echo "Installing font $folder_name to $dest_path..."
    
    if [ -d "$dest_path" ]; then
        echo "Updating existing installation..."
    else
        mkdir -p "$dest_path"
    fi

    find "$source_path" -type f \( -name "*.ttf" -o -name "*.otf" \) -exec cp {} "$dest_path" \;
}

echo "Installing fonts from fonts/ directory..."

install_local_font "Inter" "Inter"
install_local_font "JetBrains_Mono" "JetBrains_Mono"

echo "Refreshing font cache..."
fc-cache -f -v > /dev/null

echo "Applying system-wide defaults..."

mkdir -p /etc/dconf/profile
mkdir -p /etc/dconf/db/local.d

# Ensure user profile exists
if [ ! -f /etc/dconf/profile/user ]; then
    echo -e "user-db:user\nsystem-db:local" > /etc/dconf/profile/user
fi

# Create the configuration file for defaults
cat > /etc/dconf/db/local.d/01-custom-setup <<EOF
[org/gnome/desktop/Interface]
font-name='Inter Regular 11'
document-font-name='Inter Regular 11'
monospace-font-name='JetBrains Mono Regular 10'
enable-hot-corners=false

[org/gnome/desktop/wm/preferences]
titlebar-font='Inter Bold 11'

EOF

echo "Updating system dconf database..."
dconf update

echo "Installing GNOME tools..."
apt-get update -qq
apt-get install -y gnome-tweaks gnome-shell-extension-manager unzip wget jq curl

echo "Installing GNOME extensions..."

EXT_DIR="/usr/share/gnome-shell/extensions"

install_extension_by_id() {
    local ext_id=$1
    
    echo "Processing extension ID: $ext_id"
    
    # Get GNOME Shell version
    local shell_ver
    shell_ver=$(gnome-shell --version | cut -d ' ' -f 3 | cut -d . -f 1)
    
    # Query the GNOME Extensions API using the numeric ID (pk)
    local info_url="https://extensions.gnome.org/extension-info/?pk=$ext_id&shell_version=$shell_ver"
    local json_response
    json_response=$(curl -s "$info_url")
    
    local download_partial_url
    download_partial_url=$(echo "$json_response" | jq -r '.download_url')
    
    local uuid
    uuid=$(echo "$json_response" | jq -r '.uuid')

    if [[ "$download_partial_url" == "null" || -z "$download_partial_url" ]]; then
        echo "Could not find compatible version for Extension ID $ext_id on GNOME $shell_ver"
        return
    fi

    local download_url="https://extensions.gnome.org$download_partial_url"
    local dest="$EXT_DIR/$uuid"
    
    if [ -d "$dest" ]; then
        echo "Extension $uuid (ID: $ext_id) appears to be installed. Skipping..."
    else
        echo "Installing $uuid..."
        mkdir -p "$dest"
        local temp_zip
        temp_zip=$(mktemp)
        
        wget -q -O "$temp_zip" "$download_url"
        unzip -q -o "$temp_zip" -d "$dest"
        rm "$temp_zip"
        
        # Correct permissions
        chmod -R 644 "$dest"/*
        find "$dest" -type d -exec chmod 755 {} \;
        
        echo "Installed to $dest"
    fi
}

ID_BLUR=3193
ID_DOCK=307
ID_DING=2087

install_extension_by_id "$ID_BLUR"
install_extension_by_id "$ID_DOCK"
install_extension_by_id "$ID_DING"

echo "Loading configuration for user $ACTUAL_USER..."

CONF_DIR="$SCRIPT_DIR/conf"

if [ ! -d "$CONF_DIR" ]; then
    echo "Warning: ./conf directory not found at $CONF_DIR. Skipping dconf load."
else
    load_dconf() {
        local path=$1
        local file=$2
        if [ -f "$file" ]; then
            echo "Loading config: $file -> $path"
            # We must run dconf load as the user, connected to their DBUS session
            # Finding the DBUS address is tricky from sudo. 
            # We use `machinectl` or simpler `sudo -u` assuming user is logged in graphically.
            
            # This attempts to connect to the user's existing D-Bus session
            local user_dbus_pid
            user_dbus_pid=$(pgrep -u "$ACTUAL_USER" gnome-session | head -n 1)
            
            if [ -z "$user_dbus_pid" ]; then
                echo "User not logged in graphically. Applying to user's dconf file directly (might need re-login)."
                # This works if user isn't running dconf-service, otherwise requires dbus-launch
                sudo -u "$ACTUAL_USER" dbus-launch dconf load "$path" < "$file"
            else
                # Inject into running session
                local dbus_addr
                dbus_addr=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/"$user_dbus_pid"/environ | cut -d= -f2-)
                sudo -u "$ACTUAL_USER" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" dconf load "$path" < "$file"
            fi
        else
            echo "Config file not found: $file"
        fi
    }

    # Load configurations
    load_dconf "/org/gnome/shell/extensions/blur-my-shell/" "$CONF_DIR/blur-my-shell.conf"
    load_dconf "/org/gnome/shell/extensions/dash-to-dock/" "$CONF_DIR/dash-to-dock.conf"
    load_dconf "/org/gnome/shell/extensions/ding/" "$CONF_DIR/ding.conf"
fi

# Enable the extensions for the user
echo "Enabling extensions for $ACTUAL_USER..."

# Standard UUIDs for these extensions
UUID_BLUR="blur-my-shell@aunetx"
UUID_DOCK="dash-to-dock@micxgx.gmail.com"
UUID_DING="ding@rastersoft.com"

# We generate a script to run as the user to enable extensions
sudo -u "$ACTUAL_USER" bash << EOF
    gnome-extensions enable $UUID_BLUR 2>/dev/null
    gnome-extensions enable $UUID_DOCK 2>/dev/null
    gnome-extensions enable $UUID_DING 2>/dev/null
EOF

echo "SETUP COMPLETE"
echo "You may need to log out and log back in for changes to take effect"
