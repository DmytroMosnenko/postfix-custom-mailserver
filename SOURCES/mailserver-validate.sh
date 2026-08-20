#!/bin/bash
set -u

errors=0

check() {
    if "$@"; then
        printf 'OK: %s\n' "$*"
    else
        printf 'FAIL: %s\n' "$*" >&2
        errors=$((errors + 1))
    fi
}

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

check postfix check
check postconf -n
check systemctl is-enabled postfix.service
check systemctl is-enabled opendkim.service

if systemctl is-active --quiet postfix.service; then
    check systemctl is-active postfix.service
fi
if systemctl is-active --quiet opendkim.service; then
    check systemctl is-active opendkim.service
fi

if command -v ss >/dev/null 2>&1; then
    echo "OpenDKIM listener check:"
    ss -ltn | awk '$4 == "127.0.0.1:8891" { found=1 } END { exit(found ? 0 : 1) }' \
        && echo "OK: 127.0.0.1:8891 is listening" \
        || echo "WARN: 127.0.0.1:8891 is not currently listening"
fi

exit "$errors"
