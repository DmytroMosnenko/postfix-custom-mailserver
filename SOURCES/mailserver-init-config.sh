#!/bin/bash
# mailserver-init-config.sh — interactively create /etc/postfix-custom-mailserver.conf
# Part of postfix-custom-mailserver RPM.
# Usage: mailserver-init-config.sh [--force]
set -u

CONF="${PCM_CONF:-/etc/postfix-custom-mailserver.conf}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

if [ -e "$CONF" ] && [ "$FORCE" -ne 1 ]; then
    echo "[postfix-custom-mailserver] $CONF already exists (use --force to overwrite)"
    exit 0
fi

if [ ! -t 0 ]; then
    echo "ERROR: no terminal attached; create $CONF manually (see README)" >&2
    exit 1
fi

default_host="$(postconf -h myhostname 2>/dev/null || true)"
case "$default_host" in *.*) ;; *) default_host="" ;; esac

echo
echo "TLS certificate setup (Let's Encrypt) — values are saved to $CONF"

while :; do
    read -r -p "Mail server hostname (FQDN)${default_host:+ [$default_host]}: " host
    host="${host:-$default_host}"
    if [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then break; fi
    echo "  Enter a valid hostname such as mail.example.com"
done

while :; do
    read -r -p "Contact email for Let's Encrypt notices: " email
    if [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then break; fi
    echo "  Enter a valid email address"
done

umask 077
printf 'PCM_TLS_CERT_NAME=%s\nPCM_CERTBOT_EMAIL=%s\n' "$host" "$email" > "$CONF" \
    || { echo "ERROR: cannot write $CONF" >&2; exit 1; }
chown root:root "$CONF"
echo "[postfix-custom-mailserver] wrote $CONF"
