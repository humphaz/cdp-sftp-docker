#!/bin/bash
set -euo pipefail

# Check if jq is installed
if ! command -v jq &>/dev/null; then
    echo "jq is required but not installed. Please ensure jq is available in the container."
    exit 1
fi

# Configuration directory and files
CONFIG_DIR="/data/config/sftp"
USER_DIR="/data/sftp"
SFTP_CONFIG="$CONFIG_DIR/sftp_config.json"

# OpenSSH chroot requires all path components to be root-owned and not writable.
ensure_chroot_base_permissions() {
    mkdir -p /data "$USER_DIR"
    chown root:root /data "$USER_DIR"
    chmod 755 /data "$USER_DIR"
}

enforce_user_home_permissions() {
    local user=$1
    local user_home=$2
    local uid

    if ! id "$user" &>/dev/null; then
        return
    fi

    uid=$(id -u "$user")

    # Chroot root must be owned by root and not writable by group/others.
    mkdir -p "$user_home"
    chown root:root "$user_home"
    chmod 755 "$user_home"

    # Keep a writable area for SFTP activity.
    mkdir -p "$user_home/upload"

    # Everything inside the chroot can belong to the SFTP user.
    find "$user_home" -mindepth 1 -exec chown -h "$uid:users" {} +
}

enforce_existing_user_homes() {
    while IFS=: read -r user _ _ _ _ home _; do
        if [[ "$home" == "$USER_DIR"/* ]]; then
            enforce_user_home_permissions "$user" "$home"
        fi
    done < /etc/passwd
}

# Function to create/update a user and enforce chroot-safe permissions.
create_user() {
    local user=$1
    local password=$2
    local user_home="$USER_DIR/$user"

    if [[ -z "$user" || -z "$password" ]]; then
        echo "Skipping invalid user entry (missing user/password)."
        return
    fi

    # Create the user with atmoz-compatible defaults and fixed home.
    if ! id "$user" &>/dev/null; then
        useradd --no-user-group --badname -M -d "$user_home" "$user"
    fi

    enforce_user_home_permissions "$user" "$user_home"

    # Encrypt password and set it for the user
    echo "$user:$password" | chpasswd
}

ensure_chroot_base_permissions
enforce_existing_user_homes

# Check if the configuration file exists and read it to set up users
if [[ -f "$SFTP_CONFIG" ]]; then
    while IFS= read -r line; do
        # Extract user and password from JSON config
        user=$(echo "$line" | jq -r '.user')
        password=$(echo "$line" | jq -r '.password')

        # Create user with specified settings
        create_user "$user" "$password"
    done < <(jq -c '.users[]' "$SFTP_CONFIG")
else
    echo "Configuration file $SFTP_CONFIG not found!"
fi

# Start the SSH server
exec /usr/sbin/sshd -D -e

