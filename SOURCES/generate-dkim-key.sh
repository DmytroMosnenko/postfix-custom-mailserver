#!/bin/bash
set -euo pipefail

DOMAIN="${1:-}"
KEY_SELECTOR="${2:-mail}"
KEY_ROOT="/etc/opendkim/keys"
KEY_DIR="$KEY_ROOT/$DOMAIN"
KEY_TABLE="/etc/opendkim/KeyTable"
SIGNING_TABLE="/etc/opendkim/SigningTable"

usage() {
    echo "Usage: $0 DOMAIN [SELECTOR]"
    echo "Example: $0 example.com mail"
}

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
[ -n "$DOMAIN" ] || { usage >&2; exit 1; }

if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "ERROR: invalid domain: $DOMAIN" >&2
    exit 1
fi
if ! [[ "$KEY_SELECTOR" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: invalid selector: $KEY_SELECTOR" >&2
    exit 1
fi

getent passwd opendkim >/dev/null || { echo "ERROR: opendkim user not found" >&2; exit 1; }
getent group opendkim >/dev/null || { echo "ERROR: opendkim group not found" >&2; exit 1; }
command -v opendkim-genkey >/dev/null || { echo "ERROR: opendkim-genkey not found" >&2; exit 1; }

install -d -o opendkim -g opendkim -m 0750 "$KEY_ROOT" "$KEY_DIR"

if [ -e "$KEY_DIR/$KEY_SELECTOR.private" ] || [ -e "$KEY_DIR/$KEY_SELECTOR.txt" ]; then
    if [ ! -f "$KEY_DIR/$KEY_SELECTOR.private" ] || [ ! -f "$KEY_DIR/$KEY_SELECTOR.txt" ]; then
        echo "ERROR: incomplete existing DKIM key set in $KEY_DIR" >&2
        exit 1
    fi
    echo "DKIM keys already exist for $DOMAIN/$KEY_SELECTOR; not replacing them."
else
    echo "Generating 2048-bit DKIM key for $DOMAIN/$KEY_SELECTOR..."
    opendkim-genkey -b 2048 -d "$DOMAIN" -s "$KEY_SELECTOR" -D "$KEY_DIR"
fi

chown opendkim:opendkim "$KEY_DIR/$KEY_SELECTOR.private"
chmod 0600 "$KEY_DIR/$KEY_SELECTOR.private"
chown opendkim:opendkim "$KEY_DIR/$KEY_SELECTOR.txt"
chmod 0644 "$KEY_DIR/$KEY_SELECTOR.txt"

KEY_NAME="$KEY_SELECTOR._domainkey.$DOMAIN"
KEY_VALUE="$DOMAIN:$KEY_SELECTOR:$KEY_DIR/$KEY_SELECTOR.private"
SIGNING_VALUE="*@$DOMAIN $KEY_NAME"

if ! grep -Fqx "$KEY_NAME $KEY_VALUE" "$KEY_TABLE" 2>/dev/null; then
    printf '%s\n' "$KEY_NAME $KEY_VALUE" >> "$KEY_TABLE"
fi
if ! grep -Fqx "$SIGNING_VALUE" "$SIGNING_TABLE" 2>/dev/null; then
    printf '%s\n' "$SIGNING_VALUE" >> "$SIGNING_TABLE"
fi

chown opendkim:opendkim "$KEY_TABLE" "$SIGNING_TABLE"
chmod 0644 "$KEY_TABLE" "$SIGNING_TABLE"

postfix check
if command -v opendkim-testkey >/dev/null 2>&1; then
    echo "Local OpenDKIM key files created. DNS propagation is required before a remote opendkim-testkey check can succeed."
fi

if systemctl is-active --quiet opendkim.service; then
    systemctl reload-or-restart opendkim.service
fi
if systemctl is-active --quiet postfix.service; then
    systemctl reload-or-restart postfix.service
fi

echo "--------------------------------------------------------"
echo "DKIM configuration ready for $DOMAIN"
echo "--------------------------------------------------------"
echo "Add the TXT record below to DNS:"
cat "$KEY_DIR/$KEY_SELECTOR.txt"
echo "--------------------------------------------------------"
