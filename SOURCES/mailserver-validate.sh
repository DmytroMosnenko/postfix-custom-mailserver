#!/usr/bin/env bash

set -euo pipefail

ERRORS=0

fail() {
    echo "ERROR: $*" >&2
    ERRORS=$((ERRORS + 1))
}

echo "=== postfix-custom-mailserver validation ==="
echo

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

if rpm -q postfix >/dev/null 2>&1; then
    echo "OK: postfix installed"
else
    fail "postfix is not installed"
fi

if rpm -q opendkim >/dev/null 2>&1; then
    echo "OK: opendkim installed"
else
    fail "opendkim is not installed"
fi

# ---------------------------------------------------------------------------
# Configuration syntax
# ---------------------------------------------------------------------------

if postfix check >/dev/null 2>&1; then
    echo "OK: postfix check"
else
    fail "postfix check failed"
fi

# ---------------------------------------------------------------------------
# Required Postfix settings
# ---------------------------------------------------------------------------

check_postconf() {
    local name="$1"
    local expected="$2"
    local actual

    actual="$(postconf -h "${name}" 2>/dev/null || true)"

    if [[ "${actual}" == "${expected}" ]]; then
        echo "OK: ${name} = ${actual}"
    else
        fail "${name}: expected '${expected}', got '${actual}'"
    fi
}

check_postconf "inet_interfaces" "all"
check_postconf "smtpd_milters" "inet:127.0.0.1:8891"
check_postconf "non_smtpd_milters" "inet:127.0.0.1:8891"

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

if systemctl is-enabled --quiet postfix.service; then
    echo "OK: postfix.service enabled"
else
    fail "postfix.service is not enabled"
fi

if systemctl is-enabled --quiet opendkim.service; then
    echo "OK: opendkim.service enabled"
else
    fail "opendkim.service is not enabled"
fi

if systemctl is-active --quiet postfix.service; then
    echo "OK: postfix.service active"
else
    fail "postfix.service is not active"
fi

if systemctl is-active --quiet opendkim.service; then
    echo "OK: opendkim.service active"
else
    fail "opendkim.service is not active"
fi

# ---------------------------------------------------------------------------
# OpenDKIM listener
# ---------------------------------------------------------------------------

echo
echo "OpenDKIM listener check:"

if ss -lnt | grep -q '127\.0\.0\.1:8891'; then
    echo "OK: 127.0.0.1:8891 is listening"
else
    fail "127.0.0.1:8891 is not listening"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo

if [[ "${ERRORS}" -eq 0 ]]; then
    echo "=== VALIDATION PASSED ==="
    exit 0
fi

echo "=== VALIDATION FAILED: ${ERRORS} error(s) ===" >&2
exit 1