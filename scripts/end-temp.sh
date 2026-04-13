#!/bin/sh

# --- Exit codes ---
ERR_RM_FAILED=21

error_exit() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
    exit "${2:-1}"
}

echo "--- Cleanup temp directories ---"
rm -rf /tmp/var/repo /tmp/root 2>/dev/null

for dir in "/tmp/var/repo" "/tmp/root"; do
    if [ -d "$dir" ]; then
        error_exit "Error while removing $dir!" $ERR_RM_FAILED
    fi
done

echo -e "\033[32m--- Done! ---\033[0m"

echo -e "\033[33m[NOTE]\033[0m The PATH variable for the current terminal will be cleared when it is closed. If you need to clear it right now without restarting the shell, run:"
echo "hash -r && export PATH=\$(echo \$PATH | sed -e 's|/tmp/root:||g')"

exit 0
