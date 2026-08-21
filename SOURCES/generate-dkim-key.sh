#!/bin/bash
# generate-dkim-key.sh — generate DKIM keys and register them with OpenDKIM
# Part of postfix-custom-mailserver RPM.
#
# Usage: generate-dkim-key.sh DOMAIN [SELECTOR]
#   DOMAIN    The mail domain (e.g. example.com)
#   SELECTOR  The DKIM selector (default: mail)
#
# Idempotent: if keys already exist for DOMAIN/SELECTOR, they are not replaced.
# Appends to KeyTable/SigningTable only if the entry is absent.
set -uo pipefail

DOMAIN="${1:-}"
KEY_SELECTOR="${2:-mail}"
KEY_ROOT="/etc/opendkim/keys"
KEY_TABLE="/etc/opendkim/KeyTable"
SIGNING_TABLE="/etc/opendkim/SigningTable"

# ---------------------------------------------------------------------------
log()  { printf '[generate-dkim-key] %s\n' "$*"; }
die()  { printf '[generate-dkim-key] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must be run as root"

[ -n "$DOMAIN" ] || {
    echo "Usage: $0 DOMAIN [SELECTOR]"
    echo "  Example: $0 example.com mail"
    exit 1
}

# Basic domain validation (no path traversal, no shell metacharacters)
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "invalid domain name: '$DOMAIN'"

[[ "$KEY_SELECTOR" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "invalid selector: '$KEY_SELECTOR'"

getent passwd opendkim >/dev/null 2>&1 || die "opendkim user not found; install opendkim first"
getent group  opendkim >/dev/null 2>&1 || die "opendkim group not found"
command -v opendkim-genkey >/dev/null 2>&1 || die "opendkim-genkey not found; install opendkim-tools"
command -v postfix >/dev/null 2>&1 || die "postfix not found"

[ -f "$KEY_TABLE" ]    || die "$KEY_TABLE not found; run mailserver-configure.sh --apply first"
[ -f "$SIGNING_TABLE" ] || die "$SIGNING_TABLE not found; run mailserver-configure.sh --apply first"

KEY_DIR="${KEY_ROOT}/${DOMAIN}"
PRIVATE_KEY="${KEY_DIR}/${KEY_SELECTOR}.private"
TXT_RECORD="${KEY_DIR}/${KEY_SELECTOR}.txt"

# ---------------------------------------------------------------------------
# Key generation (skip if both files already exist and are non-empty)
# ---------------------------------------------------------------------------
install -d -o opendkim -g opendkim -m 0750 "$KEY_ROOT" "$KEY_DIR"

if [ -s "$PRIVATE_KEY" ] && [ -s "$TXT_RECORD" ]; then
    log "DKIM keys already exist for ${DOMAIN}/${KEY_SELECTOR} — not regenerating"
else
    # If one file exists but not the other, the key set is corrupt
    if [ -e "$PRIVATE_KEY" ] || [ -e "$TXT_RECORD" ]; then
        die "incomplete DKIM key set in $KEY_DIR (expected both .private and .txt). " \
            "Remove them manually if you want to regenerate."
    fi
    log "generating 2048-bit DKIM key for ${DOMAIN} (selector: ${KEY_SELECTOR})..."
    opendkim-genkey -b 2048 -d "$DOMAIN" -s "$KEY_SELECTOR" -D "$KEY_DIR" \
        || die "opendkim-genkey failed"
    log "key generation complete"
fi

# Always enforce correct ownership and permissions
chown opendkim:opendkim "$PRIVATE_KEY" "$TXT_RECORD"
chmod 0600 "$PRIVATE_KEY"
chmod 0644 "$TXT_RECORD"
chown opendkim:opendkim "$KEY_ROOT" "$KEY_DIR"

# ---------------------------------------------------------------------------
# Register in KeyTable and SigningTable (idempotent)
# ---------------------------------------------------------------------------
KEY_ENTRY="${KEY_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${KEY_SELECTOR}:${PRIVATE_KEY}"
SIGN_ENTRY="*@${DOMAIN} ${KEY_SELECTOR}._domainkey.${DOMAIN}"

if grep -Fqx "$KEY_ENTRY" "$KEY_TABLE" 2>/dev/null; then
    log "KeyTable already contains entry for ${DOMAIN}/${KEY_SELECTOR}"
else
    printf '%s\n' "$KEY_ENTRY" >> "$KEY_TABLE"
    log "added to KeyTable: $KEY_ENTRY"
fi

if grep -Fqx "$SIGN_ENTRY" "$SIGNING_TABLE" 2>/dev/null; then
    log "SigningTable already contains entry for ${DOMAIN}"
else
    printf '%s\n' "$SIGN_ENTRY" >> "$SIGNING_TABLE"
    log "added to SigningTable: $SIGN_ENTRY"
fi

chown opendkim:opendkim "$KEY_TABLE" "$SIGNING_TABLE"
chmod 0644 "$KEY_TABLE" "$SIGNING_TABLE"

# ---------------------------------------------------------------------------
# Reload services (only if active)
# ---------------------------------------------------------------------------
postfix check 2>&1 || { echo "WARNING: postfix check reported issues" >&2; }

if systemctl is-active --quiet opendkim.service; then
    systemctl reload-or-restart opendkim.service \
        && log "opendkim reloaded" \
        || echo "WARNING: opendkim reload failed" >&2
else
    log "opendkim is not running — will pick up config on next start"
fi

if systemctl is-active --quiet postfix.service; then
    systemctl reload-or-restart postfix.service \
        && log "postfix reloaded" \
        || echo "WARNING: postfix reload failed" >&2
fi

# ---------------------------------------------------------------------------
# Show DNS record to add
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " DKIM setup complete for: ${DOMAIN} (selector: ${KEY_SELECTOR})"
echo "================================================================"
echo ""
echo " Add this TXT record to your DNS zone for ${DOMAIN}:"
echo " (Record name: ${KEY_SELECTOR}._domainkey.${DOMAIN})"
echo ""
cat "$TXT_RECORD"
echo ""
echo "================================================================"
echo " After DNS propagates, verify with:"
echo "   opendkim-testkey -d ${DOMAIN} -s ${KEY_SELECTOR} -vvv"
echo ""
echo " Also add SPF and DMARC records if not already present:"
echo "   SPF:    ${DOMAIN} TXT \"v=spf1 a mx ~all\""
echo "   DMARC:  _dmarc.${DOMAIN} TXT \"v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}\""
echo "================================================================"
