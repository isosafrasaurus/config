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
    # IMPORTANT: install into /usr/share/fonts, not /usr/local/share/fonts
    local dest_path="/usr/share/fonts/$dest_name"

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

    # Make sure permissions are sane
    find "$dest_path" -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$dest_path" -type d -exec chmod 755 {} \; 2>/dev/null || true
}

install_icon_theme() {
    local theme_name=$1
    local source_path="$SCRIPT_DIR/$theme_name"
    local dest_path="/usr/share/icons/$theme_name"

    if [ ! -d "$source_path" ]; then
        echo "Warning: Icon theme directory not found: $source_path"
        return
    fi

    echo "Installing icon theme $theme_name to $dest_path..."

    if [ -d "$dest_path" ]; then
        echo "Updating existing icon theme installation..."
        rm -rf "$dest_path"
    fi

    mkdir -p "$(dirname "$dest_path")"
    cp -r "$source_path" "$dest_path"

    # Update icon cache if possible
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        if [ -f "$dest_path/index.theme" ]; then
            echo "Updating icon cache for $theme_name..."
            gtk-update-icon-cache -f -t "$dest_path" || true
        fi
    fi
}

echo "Installing fonts from fonts/ directory..."

install_local_font "Inter" "Inter"
install_local_font "JetBrains_Mono" "JetBrains_Mono"

echo "Refreshing font cache (system)..."
fc-cache -f -v > /dev/null || true

echo "Refreshing font cache for user $ACTUAL_USER..."
sudo -u "$ACTUAL_USER" fc-cache -f -v > /dev/null 2>&1 || true

JB_FAMILY="JetBrains Mono" 

if command -v fc-list >/dev/null 2>&1; then
    DETECTED_JB=$(fc-list -f '%{family}\n' | grep -i 'jetbrains' | head -n1 | sed 's/,.*//' || true)
    if [ -n "$DETECTED_JB" ]; then
        JB_FAMILY="$DETECTED_JB"
        echo "Detected JetBrains monospace family from fontconfig: '$JB_FAMILY'"
    else
        echo "Warning: fc-list could not find any JetBrains font family. Falling back to '$JB_FAMILY'."
        echo "Check that fonts/JetBrains_Mono actually contains .ttf/.otf files."
    fi
else
    echo "Warning: fc-list not found; assuming JetBrains family is '$JB_FAMILY'."
fi

echo "Applying system-wide defaults..."

mkdir -p /etc/dconf/profile
mkdir -p /etc/dconf/db/local.d

# Ensure user profile exists (normal user sessions)
if [ ! -f /etc/dconf/profile/user ]; then
    cat << 'EOF' > /etc/dconf/profile/user
user-db:user
system-db:local
EOF
fi

# Create the configuration file for system-wide defaults (user sessions)
cat > /etc/dconf/db/local.d/01-custom-setup <<EOF
[org/gnome/desktop/interface]
font-name='Inter 11'
document-font-name='Inter 11'
monospace-font-name='${JB_FAMILY} 10'
enable-hot-corners=false

[org/gnome/desktop/wm/preferences]
titlebar-font='Inter Bold 11'

EOF

# GDM system database; may or may not be honored on your distro
mkdir -p /etc/dconf/db/gdm.d

cat > /etc/dconf/db/gdm.d/01-gdm-fonts <<EOF
[org/gnome/desktop/interface]
font-name='Inter 11'
document-font-name='Inter 11'
monospace-font-name='${JB_FAMILY} 10'

[org/gnome/desktop/wm/preferences]
titlebar-font='Inter Bold 11'

EOF

# Ensure GDM dconf profile exists
if [ ! -f /etc/dconf/profile/gdm ]; then
    cat << 'EOF' > /etc/dconf/profile/gdm
user-db:user
system-db:gdm
EOF
fi

echo "Updating system dconf database..."
dconf update

echo "Installing GNOME tools..."
apt-get update -qq
apt-get install -y \
    gnome-tweaks \
    gnome-shell-extension-manager \
    unzip \
    wget \
    jq \
    curl \
    libglib2.0-bin \
    libgtk-3-bin \
    python3 \
    dbus-user-session

echo "Installing Mkos-Big-Sur icon theme..."
install_icon_theme "mkosbigsur"

echo "Installing GNOME extensions..."

EXT_DIR="/usr/share/gnome-shell/extensions"

install_extension_by_id() {
    local ext_id=$1
    
    echo "Processing extension ID: $ext_id"
    
    # Get GNOME Shell major version
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
        echo "Extension $uuid (ID: $ext_id) appears to be installed. Skipping download..."
    else
        echo "Installing $uuid..."
        mkdir -p "$dest"
        local temp_zip
        temp_zip=$(mktemp)
        
        wget -q -O "$temp_zip" "$download_url"
        unzip -q -o "$temp_zip" -d "$dest"
        rm "$temp_zip"
        
        echo "Installed to $dest"
    fi

    # In all cases, ensure schemas are compiled if present
    if [ -d "$dest/schemas" ]; then
        if ls "$dest/schemas"/*.gschema.xml >/dev/null 2>&1; then
            echo "Compiling GSettings schemas for $uuid..."
            glib-compile-schemas "$dest/schemas"
        fi
    fi

    # Correct permissions
    chmod -R 644 "$dest"/* 2>/dev/null || true
    find "$dest" -type d -exec chmod 755 {} \; 2>/dev/null || true
}

ID_BLUR=3193
ID_DOCK=307
ID_DING=2087

install_extension_by_id "$ID_BLUR"
install_extension_by_id "$ID_DOCK"
install_extension_by_id "$ID_DING"

echo "Loading configuration for user $ACTUAL_USER..."

CONF_DIR="$SCRIPT_DIR"

load_dconf() {
    local path=$1
    local file=$2
    if [ -f "$file" ]; then
        echo "Loading config: $file -> $path"
        # Use a temporary DBus session to write to the user's dconf database
        sudo -u "$ACTUAL_USER" dbus-run-session -- dconf load "$path" < "$file"
    else
        echo "Config file not found: $file"
    fi
}

if [ ! -d "$CONF_DIR" ]; then
    echo "Warning: ./conf directory not found at $CONF_DIR. Skipping dconf load."
else
    load_dconf "/org/gnome/shell/extensions/blur-my-shell/" "$CONF_DIR/blur-my-shell.conf"
    load_dconf "/org/gnome/shell/extensions/dash-to-dock/" "$CONF_DIR/dash-to-dock.conf"
    load_dconf "/org/gnome/shell/extensions/ding/" "$CONF_DIR/ding.conf"
fi

# Standard UUIDs for these extensions
UUID_BLUR="blur-my-shell@aunetx"
UUID_DOCK="dash-to-dock@micxgx.gmail.com"
UUID_DING="ding@rastersoft.com"

echo "Applying per-user GNOME settings, icon theme, and enabling extensions for $ACTUAL_USER..."

sudo -u "$ACTUAL_USER" dbus-run-session -- python3 - <<EOF
import subprocess, ast

def gsettings_set(schema, key, value):
    subprocess.check_call(["gsettings", "set", schema, key, value])

def gsettings_get(schema, key):
    out = subprocess.check_output(
        ["gsettings", "get", schema, key],
        text=True,
    ).strip()
    return out

JB_FAMILY = "${JB_FAMILY}"
mono_font = f"{JB_FAMILY} 10"

# Set fonts for the user session
gsettings_set("org.gnome.desktop.interface", "font-name", "Inter 11")
gsettings_set("org.gnome.desktop.interface", "document-font-name", "Inter 11")
gsettings_set("org.gnome.desktop.interface", "monospace-font-name", mono_font)
gsettings_set("org.gnome.desktop.wm.preferences", "titlebar-font", "Inter Bold 11")

# Set icon theme for the user
gsettings_set("org.gnome.desktop.interface", "icon-theme", "Mkos-Big-Sur")

# Ensure extensions are enabled
uuids_to_enable = [
    "blur-my-shell@aunetx",
    "dash-to-dock@micxgx.gmail.com",
    "ding@rastersoft.com",
]

def get_enabled_extensions():
    try:
        out = gsettings_get("org.gnome.shell", "enabled-extensions")
    except subprocess.CalledProcessError:
        return []

    # gsettings may prefix with '@as '
    if out.startswith("@as "):
        out = out[4:]

    try:
        current = ast.literal_eval(out)
        if not isinstance(current, list):
            return []
        return current
    except Exception:
        return []

enabled = get_enabled_extensions()
changed = False

for uid in uuids_to_enable:
    if uid not in enabled:
        enabled.append(uid)
        changed = True

if changed:
    subprocess.check_call(
        ["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(enabled)]
    )
EOF

echo "Attempting to apply fonts (and icon theme) to GDM / lock screen..."

# Try to detect the GDM user account used by your distro
GDM_USER=""
if getent passwd gdm >/dev/null 2>&1; then
    GDM_USER="gdm"
elif getent passwd Debian-gdm >/dev/null 2>&1; then
    GDM_USER="Debian-gdm"
elif getent passwd gdm3 >/dev/null 2>&1; then
    GDM_USER="gdm3"
fi

if [ -n "$GDM_USER" ]; then
    echo "Detected GDM user: $GDM_USER. Setting fonts via gsettings..."

    sudo -u "$GDM_USER" dbus-run-session -- gsettings set org.gnome.desktop.interface font-name 'Inter 11' || true
    sudo -u "$GDM_USER" dbus-run-session -- gsettings set org.gnome.desktop.interface document-font-name 'Inter 11' || true
    sudo -u "$GDM_USER" dbus-run-session -- gsettings set org.gnome.desktop.interface monospace-font-name "${JB_FAMILY} 10" || true
    sudo -u "$GDM_USER" dbus-run-session -- gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Inter Bold 11' || true

    # Optional: also give the login screen the Mkos-Big-Sur icons
    sudo -u "$GDM_USER" dbus-run-session -- gsettings set org.gnome.desktop.interface icon-theme 'Mkos-Big-Sur' || true
else
    echo "No GDM user found (gdm / Debian-gdm / gdm3). Skipping lock-screen font override."
fi

echo "SETUP COMPLETE"
echo "For lock-screen and greeter changes, reboot or restart GDM (e.g., 'sudo systemctl restart gdm3')."

