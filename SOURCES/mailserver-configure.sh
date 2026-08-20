#!/bin/bash
set -u

readonly POSTFIX_MAIN_CF="/etc/postfix/main.cf"
readonly OPENDKIM_CONF="/etc/opendkim.conf"
readonly OPENDKIM_DIR="/etc/opendkim"
readonly TRUSTED_HOSTS="${OPENDKIM_DIR}/TrustedHosts"
readonly KEY_TABLE="${OPENDKIM_DIR}/KeyTable"
readonly SIGNING_TABLE="${OPENDKIM_DIR}/SigningTable"
readonly MARKER_START="# BEGIN postfix-custom-mailserver"
readonly MARKER_END="# END postfix-custom-mailserver"
readonly OPENDKIM_MARKER_START="# BEGIN postfix-custom-mailserver"
readonly OPENDKIM_MARKER_END="# END postfix-custom-mailserver"
readonly POSTFIX_BACKUP="/etc/postfix/main.cf.postfix-custom-mailserver.orig"
readonly OPENDKIM_BACKUP="/etc/opendkim.conf.postfix-custom-mailserver.orig"

log() { printf '[postfix-custom-mailserver] %s\n' "$*"; }
warn() { printf '[postfix-custom-mailserver] WARNING: %s\n' "$*" >&2; }
die() { printf '[postfix-custom-mailserver] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must be run as root"
}

require_cmds() {
    local cmd
    for cmd in awk sed grep install mktemp systemctl postfix postconf; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
    done
}

backup_once() {
    local src="$1" backup="$2"
    [ -f "$src" ] || return 0
    [ -e "$backup" ] || cp -a -- "$src" "$backup"
}

replace_managed_block() {
    local file="$1" start="$2" end="$3" block_file="$4"
    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1

    awk -v start="$start" -v end="$end" -v replacement="$block_file" '
        BEGIN { in_block=0; inserted=0 }
        $0 == start {
            if (!inserted) {
                while ((getline line < replacement) > 0) print line
                close(replacement)
                inserted=1
            }
            in_block=1
            next
        }
        $0 == end {
            in_block=0
            next
        }
        !in_block { print }
        END {
            if (!inserted) {
                # The replacement is appended by the shell below.
            }
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    if ! grep -Fxq "$start" "$file" 2>/dev/null; then
        cat "$block_file" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

apply_postfix() {
    [ -f "$POSTFIX_MAIN_CF" ] || die "$POSTFIX_MAIN_CF does not exist"
    backup_once "$POSTFIX_MAIN_CF" "$POSTFIX_BACKUP"

    local block
    block=$(mktemp) || return 1
    cat > "$block" <<'EOB'
# BEGIN postfix-custom-mailserver
# Managed by postfix-custom-mailserver RPM. Do not edit this block manually.
inet_interfaces = all
inet_protocols = all
mynetworks = 127.0.0.1/8, [::1]/128
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = inet:127.0.0.1:8891
# END postfix-custom-mailserver
EOB

    replace_managed_block "$POSTFIX_MAIN_CF" "$MARKER_START" "$MARKER_END" "$block" || {
        rm -f "$block"
        die "failed to update $POSTFIX_MAIN_CF"
    }
    rm -f "$block"

    postconf -n >/dev/null || die "Postfix configuration validation failed"
    postfix check || die "postfix check failed"
}

ensure_opendkim_setting() {
    local key="$1" value="$2"
    local file="$OPENDKIM_CONF"
    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1

    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        $0 ~ "^[[:space:]]*#?[[:space:]]*" key "([[:space:]]|$)" {
            if (!done) { print key "                    " value; done=1 }
            next
        }
        { print }
        END { if (!done) print key "                    " value }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

apply_opendkim() {
    [ -f "$OPENDKIM_CONF" ] || die "$OPENDKIM_CONF does not exist"
    getent passwd opendkim >/dev/null 2>&1 || die "OpenDKIM user 'opendkim' does not exist"
    getent group opendkim >/dev/null 2>&1 || die "OpenDKIM group 'opendkim' does not exist"

    backup_once "$OPENDKIM_CONF" "$OPENDKIM_BACKUP"
    install -d -m 0755 "$OPENDKIM_DIR"
    touch "$KEY_TABLE" "$SIGNING_TABLE"
    chmod 0644 "$KEY_TABLE" "$SIGNING_TABLE"

    ensure_opendkim_setting Mode sv
    ensure_opendkim_setting Socket 'inet:8891@127.0.0.1'
    ensure_opendkim_setting KeyTable 'refile:/etc/opendkim/KeyTable'
    ensure_opendkim_setting SigningTable 'refile:/etc/opendkim/SigningTable'
    ensure_opendkim_setting TrustedHosts 'refile:/etc/opendkim/TrustedHosts'

    if [ ! -f "$TRUSTED_HOSTS" ]; then
        cat > "$TRUSTED_HOSTS" <<'EOT'
127.0.0.1
::1
localhost
EOT
        chmod 0644 "$TRUSTED_HOSTS"
    else
        ensure_line() {
            grep -Fqx "$1" "$TRUSTED_HOSTS" 2>/dev/null || printf '%s\n' "$1" >> "$TRUSTED_HOSTS"
        }
        ensure_line 127.0.0.1
        ensure_line ::1
        ensure_line localhost
    fi

    # Only the key directory is recursively owned by OpenDKIM. Do not change
    # ownership of distro-managed configuration files.
    install -d -o opendkim -g opendkim -m 0750 "$OPENDKIM_DIR/keys"
    chown opendkim:opendkim "$KEY_TABLE" "$SIGNING_TABLE" "$TRUSTED_HOSTS"

    if command -v opendkim-testkey >/dev/null 2>&1; then
        : # Domain-specific validation is performed by generate-dkim-key.sh.
    fi
}

restart_if_active() {
    local service="$1"
    if systemctl is-active --quiet "$service"; then
        systemctl reload-or-restart "$service" || return 1
    fi
}

apply() {
    require_root
    require_cmds
    apply_postfix
    apply_opendkim

    restart_if_active postfix.service || die "failed to reload/restart Postfix"
    restart_if_active opendkim.service || die "failed to reload/restart OpenDKIM"

    log "configuration applied successfully"
}

show_status() {
    require_root
    postfix check
    if command -v opendkim-testkey >/dev/null 2>&1; then
        log "OpenDKIM configuration file: $OPENDKIM_CONF"
    fi
    systemctl --no-pager --full status postfix.service || true
    systemctl --no-pager --full status opendkim.service || true
}

case "${1:---apply}" in
    --apply) apply ;;
    --status) show_status ;;
    --help|-h)
        echo "Usage: $0 [--apply|--status]"
        ;;
    *) die "unknown option: $1" ;;
esac
