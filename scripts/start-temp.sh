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

error_exit() {
    printf "\033[31m[ERROR]\033[0m %s\n" "$1" >&2
    exit "${2:-1}"
}

printf '%s\n' "--- System directories check ---"
if [ ! -d "/tmp" ]; then
    error_exit "Directory /tmp not found!" $ERR_TMP_MISSING
fi

printf '%s\n' "--- Temporary directories creation ---"
mkdir -p /tmp/var/repo /tmp/root || error_exit "Failed to create directory structure in /tmp" $ERR_MKDIR_FAILED

for dir in "/tmp/var/repo" "/tmp/root"; do
    [ -d "$dir" ] || error_exit "Directory $dir not created!" $ERR_MKDIR_FAILED
done

printf '%s\n' "--- PATH setup ---"
NEW_PATHS=$(find /tmp/root -type d 2>/dev/null | paste -sd ":" -)

[ -z "$NEW_PATHS" ] && error_exit "No directories found to add to PATH" $ERR_PATH_FAILED

export PATH="${NEW_PATHS}:${PATH}"

case "$PATH" in
    "${NEW_PATHS}"*) ;;
    *) error_exit "Failed to apply new paths to PATH variable" $ERR_PATH_FAILED ;;
esac

printf '%s\n' "--- Checking system configuration file ---"
if [ ! -f "$CONFIG_FILE" ]; then
    error_exit "System configuration file '$CONFIG_FILE' not found!" $ERR_CONFIG_MISSING
fi

printf '%s%s%s\n' "--- Updating paths in " "$CONFIG_FILE" "---"

UPDATED_CONFIG=$(sed -E \
    -e 's|^(database_path[ \t]*=[ \t]*).*|\1"/tmp/root/usr/upac/db"|' \
    -e 's|^(repo_path[ \t]*=[ \t]*).*|\1"/tmp/var/repo"|' \
    -e 's|^(root_path[ \t]*=[ \t]*).*|\1"/tmp/root"|' \
    "$CONFIG_FILE") || error_exit "Error parsing configuration file" $ERR_SED_FAILED

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "Root privileges are required to modify $CONFIG_FILE. Requesting sudo..."
    printf "%s\n" "$UPDATED_CONFIG" | sudo tee "$CONFIG_FILE" > /dev/null || error_exit "Error writing updated config file" $ERR_WRITE_FAILED
else
    printf "%s\n" "$UPDATED_CONFIG" > "$CONFIG_FILE" || error_exit "Error writing updated config file" $ERR_WRITE_FAILED
fi

printf "\033[32m--- Done! Exit. ---\033[0m\n"
exit 0
