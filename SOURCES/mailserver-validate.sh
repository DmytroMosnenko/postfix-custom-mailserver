#!/bin/bash
# mailserver-validate.sh — verify postfix-custom-mailserver installation
# Part of postfix-custom-mailserver RPM.
#
# Exits 0 if all checks pass, non-zero otherwise.
# Run after installation and after any manual configuration changes.
set -u

ERRORS=0
WARNINGS=0

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
RST='\033[0m'

ok()   { printf "${GRN}[ OK ]${RST} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${RST} %s\n" "$*" >&2; ERRORS=$((ERRORS + 1)); }
warn() { printf "${YEL}[WARN]${RST} %s\n" "$*"; WARNINGS=$((WARNINGS + 1)); }
info() { printf "       %s\n" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

echo "================================================================"
echo " postfix-custom-mailserver validation"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
echo "--- Package configuration files ---"
# ---------------------------------------------------------------------------

MANAGED_FILES=(
    /etc/postfix/main.cf
    /etc/opendkim.conf
    /etc/opendkim/KeyTable
    /etc/opendkim/SigningTable
    /etc/opendkim/TrustedHosts
)

for f in "${MANAGED_FILES[@]}"; do
    if [ -f "$f" ]; then
        ok "$f exists"
    else
        fail "$f is missing"
    fi
done

# Check managed block in main.cf
if [ -f /etc/postfix/main.cf ]; then
    if grep -Fxq "# BEGIN postfix-custom-mailserver" /etc/postfix/main.cf; then
        ok "managed block present in main.cf"
    else
        fail "managed block NOT found in main.cf — run mailserver-configure.sh --apply"
    fi
fi

# Check loopback-only (safety: should not be listening on all interfaces)
if [ -f /etc/postfix/main.cf ]; then
    if grep -qE "^inet_interfaces[[:space:]]*=[[:space:]]*loopback-only" /etc/postfix/main.cf; then
        ok "inet_interfaces = loopback-only (safe)"
    elif grep -qE "^inet_interfaces[[:space:]]*=[[:space:]]*all" /etc/postfix/main.cf; then
        warn "inet_interfaces = all — Postfix is listening on all interfaces; ensure firewall blocks port 25 from outside"
    fi
fi

echo ""
# ---------------------------------------------------------------------------
echo "--- Postfix configuration ---"
# ---------------------------------------------------------------------------

if postconf -n >/dev/null 2>&1; then
    ok "postconf -n: configuration is valid"
else
    fail "postconf -n: configuration errors detected"
    postconf -n 2>&1 | while IFS= read -r line; do info "$line"; done
fi

if postfix check 2>/dev/null; then
    ok "postfix check: passed"
else
    fail "postfix check: reported errors"
fi

echo ""
# ---------------------------------------------------------------------------
echo "--- Services ---"
# ---------------------------------------------------------------------------

for svc in postfix opendkim; do
    if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        ok "${svc}: enabled at boot"
    else
        warn "${svc}: NOT enabled at boot (run: systemctl enable ${svc})"
    fi

    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        ok "${svc}: running"
    else
        warn "${svc}: NOT running (run: systemctl start ${svc})"
    fi
done

echo ""
# ---------------------------------------------------------------------------
echo "--- OpenDKIM socket ---"
# ---------------------------------------------------------------------------

if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '$4 == "127.0.0.1:8891" { found=1 } END { exit(!found) }'; then
        ok "OpenDKIM is listening on 127.0.0.1:8891"
    else
        if systemctl is-active --quiet opendkim.service; then
            fail "opendkim is running but NOT listening on 127.0.0.1:8891 — check Socket in /etc/opendkim.conf"
        else
            warn "127.0.0.1:8891 is not listening (opendkim is not running)"
        fi
    fi
else
    warn "ss command not found; skipping socket check"
fi

echo ""
# ---------------------------------------------------------------------------
echo "--- DKIM keys ---"
# ---------------------------------------------------------------------------

KEY_ROOT="/etc/opendkim/keys"
if [ -d "$KEY_ROOT" ]; then
    key_count=$(find "$KEY_ROOT" -name "*.private" 2>/dev/null | wc -l)
    if [ "$key_count" -gt 0 ]; then
        ok "$key_count DKIM private key(s) found"
        find "$KEY_ROOT" -name "*.private" 2>/dev/null | while IFS= read -r key; do
            domain_dir=$(dirname "$key")
            domain=$(basename "$domain_dir")
            selector=$(basename "$key" .private)
            # Check permissions
            perms=$(stat -c '%a' "$key" 2>/dev/null)
            owner=$(stat -c '%U:%G' "$key" 2>/dev/null)
            if [ "$perms" = "600" ] && [ "$owner" = "opendkim:opendkim" ]; then
                ok "  ${domain}/${selector}: permissions ok (600, opendkim:opendkim)"
            else
                fail "  ${domain}/${selector}: bad perms/owner (got ${perms} ${owner}, need 600 opendkim:opendkim)"
            fi
        done
    else
        warn "No DKIM keys found in $KEY_ROOT — run generate-dkim-key.sh YOURDOMAIN"
    fi
else
    warn "$KEY_ROOT does not exist — run mailserver-configure.sh --apply first"
fi

# Check KeyTable entries
if [ -f /etc/opendkim/KeyTable ] && [ -s /etc/opendkim/KeyTable ]; then
    entries=$(grep -cv '^[[:space:]]*$' /etc/opendkim/KeyTable 2>/dev/null || echo 0)
    ok "KeyTable has $entries entry/entries"
else
    warn "KeyTable is empty — run generate-dkim-key.sh YOURDOMAIN"
fi

if [ -f /etc/opendkim/SigningTable ] && [ -s /etc/opendkim/SigningTable ]; then
    entries=$(grep -cv '^[[:space:]]*$' /etc/opendkim/SigningTable 2>/dev/null || echo 0)
    ok "SigningTable has $entries entry/entries"
else
    warn "SigningTable is empty — run generate-dkim-key.sh YOURDOMAIN"
fi

echo ""
# ---------------------------------------------------------------------------
echo "--- Summary ---"
# ---------------------------------------------------------------------------

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GRN}All checks passed.${RST}"
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "${YEL}${WARNINGS} warning(s), 0 errors. Review warnings above.${RST}"
else
    echo -e "${RED}${ERRORS} error(s), ${WARNINGS} warning(s). Fix errors before sending mail.${RST}"
fi

echo ""
exit "$ERRORS"
