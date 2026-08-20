#!/bin/bash
set -euo pipefail

LOCAL_USER="${1:-}"
TARGET_EMAIL="${2:-}"
ALIASES_FILE="/etc/aliases"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
[ -n "$LOCAL_USER" ] && [ -n "$TARGET_EMAIL" ] || {
    echo "Usage: $0 local_username destination@example.com" >&2
    exit 1
}

if ! [[ "$LOCAL_USER" =~ ^[A-Za-z0-9._%+-]+$ ]]; then
    echo "ERROR: invalid local alias" >&2
    exit 1
fi
if ! [[ "$TARGET_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
    echo "ERROR: invalid destination address" >&2
    exit 1
fi

# Never silently replace an existing administrator alias.
if grep -Eq "^${LOCAL_USER}:" "$ALIASES_FILE" 2>/dev/null; then
    echo "Alias '$LOCAL_USER' already exists. Edit $ALIASES_FILE manually if you want to change it."
    exit 0
fi

printf '%s: %s\n' "$LOCAL_USER" "$TARGET_EMAIL" >> "$ALIASES_FILE"
newaliases

if systemctl is-active --quiet postfix.service; then
    systemctl reload postfix.service
fi

echo "Alias added: ${LOCAL_USER} -> ${TARGET_EMAIL}"
