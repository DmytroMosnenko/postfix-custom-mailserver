#!/bin/bash
# add-alias.sh — safely add a Postfix local alias
# Part of postfix-custom-mailserver RPM.
#
# Usage: add-alias.sh LOCAL_USER DESTINATION_EMAIL
#   LOCAL_USER        Local alias name (e.g. root, noreply, webapp)
#   DESTINATION_EMAIL Where to forward (e.g. you@gmail.com)
#
# Never silently replaces existing aliases — edit /etc/aliases manually for that.
set -uo pipefail

LOCAL_USER="${1:-}"
TARGET_EMAIL="${2:-}"
ALIASES_FILE="/etc/aliases"

log() { printf '[add-alias] %s\n' "$*"; }
die() { printf '[add-alias] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root"

[ -n "$LOCAL_USER" ] && [ -n "$TARGET_EMAIL" ] || {
    echo "Usage: $0 LOCAL_USER DESTINATION_EMAIL"
    echo "  Example: $0 webapp you@gmail.com"
    exit 1
}

# Input validation
[[ "$LOCAL_USER" =~ ^[A-Za-z0-9._%+-]+$ ]] \
    || die "invalid local alias name: '$LOCAL_USER' (alphanumeric, dots, underscores, hyphens only)"

[[ "$TARGET_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die "invalid destination email address: '$TARGET_EMAIL'"

[ -f "$ALIASES_FILE" ] || die "$ALIASES_FILE not found; is postfix installed?"
command -v newaliases >/dev/null 2>&1 || die "newaliases command not found"

# Check for existing alias (case-insensitive match because aliases are case-insensitive)
if grep -iEq "^${LOCAL_USER}[[:space:]]*:" "$ALIASES_FILE" 2>/dev/null; then
    existing=$(grep -iE "^${LOCAL_USER}[[:space:]]*:" "$ALIASES_FILE")
    log "alias '${LOCAL_USER}' already exists:"
    log "  $existing"
    log "Edit $ALIASES_FILE manually to change it, then run: newaliases"
    exit 0
fi

printf '%s: %s\n' "$LOCAL_USER" "$TARGET_EMAIL" >> "$ALIASES_FILE"
newaliases || die "newaliases failed after adding alias"

if systemctl is-active --quiet postfix.service; then
    systemctl reload postfix.service \
        && log "postfix reloaded" \
        || log "WARNING: postfix reload failed — alias is registered but postfix may need a manual restart"
fi

log "alias added: ${LOCAL_USER} -> ${TARGET_EMAIL}"
