#!/bin/sh

# --- Exit codes ---
ERR_RM_FAILED=21

error_exit() {
    printf "\033[31m[ERROR]\033[0m %s\n" "$1" >&2
    exit "${2:-1}"
}

printf "--- Cleanup temp directories ---\n"
rm -rf /tmp/var/repo /tmp/root 2>/dev/null

for dir in "/tmp/var/repo" "/tmp/root"; do
    if [ -d "$dir" ]; then
        error_exit "Error while removing $dir!" $ERR_RM_FAILED
    fi
done

printf "\033[32m--- Done! ---\033[0m\n"

printf "\033[33m[NOTE]\033[0m The PATH variable for the current terminal will be cleared when it is closed. If you need to clear it right now without restarting the shell, run:\n"
printf "hash -r && export PATH=\$(echo \$PATH | sed -e 's|/tmp/root:||g')\n"

exit 0
