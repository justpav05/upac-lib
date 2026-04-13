#!/bin/sh

# --- Settings ---
CONFIG_FILE="/etc/upac/config.toml"

# --- Error codes ---
ERR_TMP_MISSING=10
ERR_MKDIR_FAILED=11
ERR_PATH_FAILED=12
ERR_CONFIG_MISSING=13
ERR_SED_FAILED=14
ERR_WRITE_FAILED=15
ERR_NOT_ROOT=16

error_exit() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
    exit "${2:-1}"
}

echo "--- System directoryes check ---"
if [ ! -d "/tmp" ]; then
    error_exit "Directory /tmp not found!" $ERR_TMP_MISSING
fi

echo "--- Temporary directories creation ---"
mkdir -p /tmp/var/repo /tmp/root || error_exit "Failed to create directory structure in /tmp" $ERR_MKDIR_FAILED

for dir in "/tmp/var/repo" "/tmp/root"; do
    [ -d "$dir" ] || error_exit "Directory $dir not created!" $ERR_MKDIR_FAILED
done

echo "--- PATH setup ---"
NEW_PATHS=$(find /tmp/root -type d 2>/dev/null | paste -sd ":" -)

[ -z "$NEW_PATHS" ] && error_exit "No directories found to add to PATH" $ERR_PATH_FAILED

export PATH="${NEW_PATHS}:${PATH}"

if [[ "$PATH" != "${NEW_PATHS}"* ]]; then
    error_exit "Failed to apply new paths to PATH variable" $ERR_PATH_FAILED
fi

echo "--- Checking system configuration file ---"
if [ ! -f "$CONFIG_FILE" ]; then
    error_exit "System configuration file '$CONFIG_FILE' not found!" $ERR_CONFIG_MISSING
fi

echo "--- Updating paths in $CONFIG_FILE ---"
if [ "$EUID" -ne 0 ]; then
    error_exit "For changing $CONFIG_FILE, root privileges are required. Run the script with sudo." $ERR_NOT_ROOT
fi

UPDATED_CONFIG=$(sed -E \
    -e 's|^(database_path[ \t]*=[ \t]*).*|\1"/tmp/var/db/upac"|' \
    -e 's|^(repo_path[ \t]*=[ \t]*).*|\1"/tmp/var/repo"|' \
    -e 's|^(root_path[ \t]*=[ \t]*).*|\1"/tmp/root"|' \
    "$CONFIG_FILE") || error_exit "Error parsing configuration file" $ERR_SED_FAILED

echo "$UPDATED_CONFIG" > "$CONFIG_FILE" || error_exit "Error writing updated config file" $ERR_WRITE_FAILED

echo -e "\033[32m--- Done! Exit. ---\033[0m"
exit 0
