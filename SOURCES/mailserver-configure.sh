#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: this script must be run as root." >&2
    exit 1
fi

if [[ "${ACTION}" != "--apply" ]]; then
    echo "Usage: $0 --apply"
    exit 2
fi

POSTFIX_MAIN_CF="/etc/postfix/main.cf"
OPENDKIM_CONF="/etc/opendkim.conf"
OPENDKIM_DIR="/etc/opendkim"
OPENDKIM_KEYS_DIR="${OPENDKIM_DIR}/keys"

echo "[postfix-custom-mailserver] Applying configuration..."

# ---------------------------------------------------------------------------
# Ensure OpenDKIM service account exists.
#
# Some distributions create this account in the OpenDKIM package scriptlet,
# while others may create it differently. Make the package self-sufficient.
# ---------------------------------------------------------------------------

if ! getent group opendkim >/dev/null; then
    echo "[postfix-custom-mailserver] Creating group 'opendkim'..."
    groupadd --system opendkim
fi

if ! getent passwd opendkim >/dev/null; then
    echo "[postfix-custom-mailserver] Creating user 'opendkim'..."
    useradd \
        --system \
        --gid opendkim \
        --home-dir /var/lib/opendkim \
        --shell /sbin/nologin \
        opendkim
fi

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

install -d -o opendkim -g opendkim -m 0750 \
    /var/lib/opendkim

install -d -o opendkim -g opendkim -m 0750 \
    "${OPENDKIM_DIR}"

install -d -o opendkim -g opendkim -m 0750 \
    "${OPENDKIM_KEYS_DIR}"

# ---------------------------------------------------------------------------
# OpenDKIM configuration
# ---------------------------------------------------------------------------

cat > "${OPENDKIM_CONF}" <<'EOF'
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes

UMask                   007

Canonicalization        relaxed/simple
Mode                    sv
OversignHeaders         From

UserID                  opendkim:opendkim
PidFile                 /run/opendkim/opendkim.pid

Socket                  inet:8891@127.0.0.1

KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
TrustedHosts            refile:/etc/opendkim/TrustedHosts
EOF

cat > "${OPENDKIM_DIR}/KeyTable" <<'EOF'
# Add DKIM keys here, for example:
#
# mail._domainkey.example.com example.com:mail:/etc/opendkim/keys/example.com/mail.private
EOF

cat > "${OPENDKIM_DIR}/SigningTable" <<'EOF'
# Add signing rules here, for example:
#
# *@example.com mail._domainkey.example.com
EOF

cat > "${OPENDKIM_DIR}/TrustedHosts" <<'EOF'
127.0.0.1
::1
localhost
EOF

chown root:opendkim \
    "${OPENDKIM_CONF}" \
    "${OPENDKIM_DIR}/KeyTable" \
    "${OPENDKIM_DIR}/SigningTable" \
    "${OPENDKIM_DIR}/TrustedHosts"

chmod 0640 \
    "${OPENDKIM_CONF}" \
    "${OPENDKIM_DIR}/KeyTable" \
    "${OPENDKIM_DIR}/SigningTable" \
    "${OPENDKIM_DIR}/TrustedHosts"

# ---------------------------------------------------------------------------
# Postfix configuration
#
# IMPORTANT:
# Always use postconf -e instead of appending to main.cf.
# This makes installation and re-installation idempotent.
# ---------------------------------------------------------------------------

postconf -e 'inet_interfaces = all'
postconf -e 'inet_protocols = all'

postconf -e 'mynetworks = 127.0.0.1/8, [::1]/128'

postconf -e 'smtpd_milters = inet:127.0.0.1:8891'
postconf -e 'non_smtpd_milters = inet:127.0.0.1:8891'

postconf -e 'milter_protocol = 6'
postconf -e 'milter_default_action = accept'

postconf -e 'smtpd_tls_security_level = may'
postconf -e 'smtp_tls_security_level = may'

postconf -e 'smtpd_tls_cert_file = /etc/pki/tls/certs/postfix.pem'
postconf -e 'smtpd_tls_key_file = /etc/pki/tls/private/postfix.key'

# Keep distribution defaults for aliases unless explicitly configured.
# We deliberately do not append alias_maps/alias_database.

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

if [[ -f /etc/postfix/main.cf ]]; then
    chmod 0644 /etc/postfix/main.cf
fi

# ---------------------------------------------------------------------------
# Validate configuration before restarting services.
# ---------------------------------------------------------------------------

echo "[postfix-custom-mailserver] Running postfix check..."
postfix check

echo "[postfix-custom-mailserver] Enabling services..."
systemctl enable postfix.service
systemctl enable opendkim.service

echo "[postfix-custom-mailserver] Restarting OpenDKIM..."
systemctl restart opendkim.service

echo "[postfix-custom-mailserver] Waiting for OpenDKIM listener..."

for _ in {1..20}; do
    if ss -lnt | grep -q '127\.0\.0\.1:8891'; then
        break
    fi

    sleep 0.5
done

if ! ss -lnt | grep -q '127\.0\.0\.1:8891'; then
    echo "ERROR: OpenDKIM failed to listen on 127.0.0.1:8891" >&2
    systemctl status opendkim.service --no-pager >&2 || true
    journalctl -u opendkim.service -n 50 --no-pager >&2 || true
    exit 1
fi

echo "[postfix-custom-mailserver] Restarting Postfix..."
systemctl restart postfix.service

# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------

if ! systemctl is-active --quiet opendkim.service; then
    echo "ERROR: OpenDKIM is not running." >&2
    systemctl status opendkim.service --no-pager >&2 || true
    exit 1
fi

if ! systemctl is-active --quiet postfix.service; then
    echo "ERROR: Postfix is not running." >&2
    systemctl status postfix.service --no-pager >&2 || true
    exit 1
fi

if ! ss -lnt | grep -q '127\.0\.0\.1:8891'; then
    echo "ERROR: OpenDKIM listener disappeared after Postfix startup." >&2
    exit 1
fi

echo "[postfix-custom-mailserver] configuration applied successfully"