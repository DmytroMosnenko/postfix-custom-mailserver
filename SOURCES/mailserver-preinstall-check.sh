#!/bin/bash
# mailserver-preinstall-check.sh — diagnose existing mail server state before RPM install
# Run this BEFORE installing the postfix-custom-mailserver RPM on a server
# that had previous (broken) installations.
#
# This script is READ-ONLY: it never modifies anything. It tells you what to
# do manually before installing the RPM.
set -u

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

ok()     { printf "${GRN}[ OK ]${RST} %s\n" "$*"; }
issue()  { printf "${RED}[ISSUE]${RST} %s\n" "$*"; }
warn()   { printf "${YEL}[WARN]${RST} %s\n" "$*"; }
info()   { printf "${CYN}[INFO]${RST} %s\n" "$*"; }
section(){ echo ""; echo "--- $* ---"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

echo "================================================================"
echo " Pre-install diagnostic for postfix-custom-mailserver"
echo "================================================================"
echo " This script does NOT modify anything."
echo " It tells you what to clean up before installing the RPM."
echo "================================================================"

ISSUES=0

section "Installed RPM packages"
for pkg in postfix opendkim opendkim-tools cyrus-sasl cyrus-sasl-plain; do
    if rpm -q "$pkg" &>/dev/null; then
        ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg")
        ok "$pkg installed ($ver)"
    else
        warn "$pkg NOT installed — will be installed as RPM dependency"
    fi
done

OLD_PKG="postfix-custom-mailserver"
if rpm -q "$OLD_PKG" &>/dev/null; then
    old_ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$OLD_PKG")
    warn "Old $OLD_PKG RPM installed ($old_ver) — will be upgraded/replaced"
    info "  Run: dnf remove $OLD_PKG   (before re-installing if you want a clean slate)"
    info "  Or:  dnf upgrade $OLD_PKG  (will do an in-place upgrade)"
fi

section "Postfix configuration state"
if [ -f /etc/postfix/main.cf ]; then
    ok "/etc/postfix/main.cf exists"

    # Check for duplicate/conflicting parameters added by old installs
    dupes=$(grep -E "^(inet_interfaces|mynetworks|smtpd_milters|non_smtpd_milters|milter_)" \
        /etc/postfix/main.cf 2>/dev/null | grep -v "^#" || true)
    if [ -n "$dupes" ]; then
        info "Current managed Postfix parameters in main.cf:"
        echo "$dupes" | while IFS= read -r line; do printf '    %s\n' "$line"; done
    fi

    # Check for old-style APPENDED blocks (Gemini/ChatGPT v1 would append, not replace)
    append_count=$(grep -c "CUSTOM MAILSERVER CONFIGURATION" /etc/postfix/main.cf 2>/dev/null || echo 0)
    if [ "$append_count" -gt 0 ]; then
        issue "Found $append_count appended configuration block(s) from old install!"
        info "  These must be removed before installing the new RPM."
        info "  Lines to remove (between the markers):"
        grep -n "CUSTOM MAILSERVER CONFIGURATION\|inet_interfaces\|mynetworks\|smtpd_milters\|non_smtpd_milters\|milter_" \
            /etc/postfix/main.cf 2>/dev/null | head -20 | while IFS= read -r line; do printf '    %s\n' "$line"; done
        info ""
        info "  AUTOMATIC FIX: Run the new RPM's configure script after install and it"
        info "  will replace the old blocks with a clean managed block automatically."
        info "  OR manually edit /etc/postfix/main.cf to remove duplicated settings."
        ISSUES=$((ISSUES + 1))
    fi

    # Check for managed block from new-style install
    if grep -Fxq "# BEGIN postfix-custom-mailserver" /etc/postfix/main.cf 2>/dev/null; then
        ok "Managed block found in main.cf (new-style install)"
    fi

    # Backup check
    for bak in /etc/postfix/main.cf.bak /etc/postfix/main.cf.pcm-orig; do
        [ -f "$bak" ] && info "Backup exists: $bak"
    done
else
    warn "/etc/postfix/main.cf not found — postfix may not be installed yet"
fi

section "OpenDKIM configuration state"
if [ -f /etc/opendkim.conf ]; then
    ok "/etc/opendkim.conf exists"

    current_socket=$(grep -E "^[[:space:]]*Socket" /etc/opendkim.conf 2>/dev/null || echo "(none)")
    info "Current Socket setting: $current_socket"

    current_mode=$(grep -E "^[[:space:]]*Mode" /etc/opendkim.conf 2>/dev/null || echo "(none)")
    info "Current Mode setting:   $current_mode"

    for bak in /etc/opendkim.conf.bak /etc/opendkim.conf.pcm-orig; do
        [ -f "$bak" ] && info "Backup exists: $bak"
    done
else
    warn "/etc/opendkim.conf not found — opendkim may not be installed yet"
fi

section "DKIM keys"
KEY_ROOT="/etc/opendkim/keys"
if [ -d "$KEY_ROOT" ]; then
    key_count=$(find "$KEY_ROOT" -name "*.private" 2>/dev/null | wc -l)
    if [ "$key_count" -gt 0 ]; then
        ok "Found $key_count existing DKIM private key(s) — they will NOT be touched by the RPM"
        find "$KEY_ROOT" -name "*.private" 2>/dev/null | while IFS= read -r k; do
            perms=$(stat -c '%a' "$k" 2>/dev/null)
            owner=$(stat -c '%U:%G' "$k" 2>/dev/null)
            domain=$(basename "$(dirname "$k")")
            sel=$(basename "$k" .private)
            if [ "$perms" = "600" ] && [ "$owner" = "opendkim:opendkim" ]; then
                ok "  ${domain}/${sel}: permissions ok"
            else
                issue "  ${domain}/${sel}: bad perms/owner (${perms} ${owner}) — fix: chown opendkim:opendkim; chmod 600"
                ISSUES=$((ISSUES + 1))
            fi
        done
    else
        warn "No DKIM keys found — you will need to run generate-dkim-key.sh after install"
    fi
else
    info "$KEY_ROOT does not exist yet — will be created by RPM install"
fi

section "Service status"
for svc in postfix opendkim; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        info "${svc}: currently running"
    else
        info "${svc}: currently stopped"
    fi
done

section "Summary and next steps"
if [ "$ISSUES" -gt 0 ]; then
    echo -e "${YEL}Found $ISSUES issue(s) above.${RST}"
    echo ""
    echo "RECOMMENDED INSTALL PROCEDURE:"
    echo ""
    echo "  Option A — Clean upgrade (recommended):"
    echo "    1. dnf install ./postfix-custom-mailserver-*.rpm"
    echo "       (RPM %post will auto-apply config, replacing old blocks)"
    echo "    2. /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh"
    echo "    3. If you had DKIM keys: they are preserved, just verify:"
    echo "       /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh"
    echo ""
    echo "  Option B — Full clean slate:"
    echo "    1. dnf remove postfix-custom-mailserver   (if old RPM installed)"
    echo "    2. cp /etc/postfix/main.cf /etc/postfix/main.cf.MANUAL_BACKUP"
    echo "    3. Edit /etc/postfix/main.cf — remove ALL lines between old markers"
    echo "       and any duplicate inet_interfaces/smtpd_milters/mynetworks lines"
    echo "    4. cp /etc/opendkim.conf /etc/opendkim.conf.MANUAL_BACKUP"
    echo "    5. dnf install ./postfix-custom-mailserver-*.rpm"
    echo "    6. /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh"
else
    echo -e "${GRN}No issues found. Ready to install.${RST}"
    echo ""
    echo "INSTALL:"
    echo "  dnf install ./postfix-custom-mailserver-*.rpm"
    echo "  /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh"
fi
echo ""
