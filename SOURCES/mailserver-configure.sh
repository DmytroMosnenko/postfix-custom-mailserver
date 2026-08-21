#!/bin/bash
# mailserver-configure.sh — idempotent Postfix + OpenDKIM configuration helper
# Part of postfix-custom-mailserver RPM.
# Safe to run multiple times; only the managed block is replaced.
set -u

readonly POSTFIX_MAIN_CF="/etc/postfix/main.cf"
readonly OPENDKIM_CONF="/etc/opendkim.conf"
readonly OPENDKIM_DIR="/etc/opendkim"
readonly TRUSTED_HOSTS="${OPENDKIM_DIR}/TrustedHosts"
readonly KEY_TABLE="${OPENDKIM_DIR}/KeyTable"
readonly SIGNING_TABLE="${OPENDKIM_DIR}/SigningTable"

readonly BLOCK_START="# BEGIN postfix-custom-mailserver"
readonly BLOCK_END="# END postfix-custom-mailserver"

readonly POSTFIX_BACKUP="${POSTFIX_MAIN_CF}.pcm-orig"
readonly OPENDKIM_BACKUP="${OPENDKIM_CONF}.pcm-orig"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[postfix-custom-mailserver] %s\n' "$*"; }
warn() { printf '[postfix-custom-mailserver] WARNING: %s\n' "$*" >&2; }
die()  { printf '[postfix-custom-mailserver] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "must be run as root"
}

require_cmds() {
    local missing=0
    for cmd in awk grep install mktemp postconf postfix systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || { warn "required command not found: $cmd"; missing=1; }
    done
    [ "$missing" -eq 0 ] || die "missing required commands (see above)"
}

# ---------------------------------------------------------------------------
# Backup (first-time only, never overwrite)
# ---------------------------------------------------------------------------
backup_once() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    if [ ! -e "$dst" ]; then
        cp -a -- "$src" "$dst"
        log "backed up $src -> $dst"
    fi
}

# ---------------------------------------------------------------------------
# Managed-block replacement (idempotent)
#
# Replaces the content between BLOCK_START and BLOCK_END in $file with the
# content in $block_file (which must include both marker lines).
# If the markers are absent, appends the block at the end of the file.
# Uses a temp file + atomic rename-via-cat to preserve original permissions.
# ---------------------------------------------------------------------------
replace_managed_block() {
    local file="$1" block_file="$2"
    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || die "mktemp failed for $file"

    # Copy permissions of original to temp file
    chmod --reference="$file" "$tmp" 2>/dev/null || true

    if grep -Fxq "$BLOCK_START" "$file" 2>/dev/null; then
        # Block exists — strip old block and write file with placeholder removed.
        awk \
            -v start="$BLOCK_START" \
            -v end="$BLOCK_END" \
            -v replacement="$block_file" '
            BEGIN { in_block=0; done=0 }
            $0 == start {
                if (!done) {
                    while ((getline line < replacement) > 0) print line
                    close(replacement)
                    done=1
                }
                in_block=1
                next
            }
            $0 == end  { in_block=0; next }
            !in_block  { print }
        ' "$file" > "$tmp" \
            || { rm -f "$tmp"; die "awk failed updating $file"; }
    else
        # Block absent — copy file unchanged and append block.
        cat "$file" > "$tmp" \
            || { rm -f "$tmp"; die "cat failed copying $file"; }
        # Ensure file ends with newline before appending
        [ -s "$tmp" ] && tail -c1 "$tmp" | grep -qP '\n' || printf '\n' >> "$tmp"
        cat "$block_file" >> "$tmp" \
            || { rm -f "$tmp"; die "append failed for $file"; }
    fi

    # Atomic overwrite (preserving inode and permissions)
    cat "$tmp" > "$file" || { rm -f "$tmp"; die "write-back failed for $file"; }
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Postfix configuration
# ---------------------------------------------------------------------------
apply_postfix() {
    [ -f "$POSTFIX_MAIN_CF" ] || die "$POSTFIX_MAIN_CF does not exist; is postfix installed?"
    backup_once "$POSTFIX_MAIN_CF" "$POSTFIX_BACKUP"

    local block
    block=$(mktemp) || die "mktemp failed"

    # NOTE: inet_interfaces = loopback-only — we only relay outbound mail from
    # localhost (Python apps, cron, etc.). This is intentionally NOT "all" to
    # avoid turning the server into an open relay.
    # NOTE: smtpd_relay_restrictions ensures we do not relay for strangers.
    # NOTE: milter is only wired for non_smtpd_milters so locally-submitted
    # mail from apps gets DKIM-signed, while inbound SMTP does not require
    # DKIM verification (we are not an inbound MX here).
    cat > "$block" << 'EOB'
# BEGIN postfix-custom-mailserver
# Managed by postfix-custom-mailserver RPM. Do not edit between these markers.
# To override, add settings BELOW this block or use /etc/postfix/main.cf.d/.
inet_interfaces        = loopback-only
inet_protocols         = all
mynetworks             = 127.0.0.0/8, [::1]/128
alias_maps             = hash:/etc/aliases
alias_database         = hash:/etc/aliases
smtpd_relay_restrictions = permit_mynetworks, reject
milter_default_action  = accept
milter_protocol        = 6
smtpd_milters          = inet:127.0.0.1:8891
non_smtpd_milters      = inet:127.0.0.1:8891
# END postfix-custom-mailserver
EOB

    replace_managed_block "$POSTFIX_MAIN_CF" "$block"
    rm -f "$block"

    postconf -n >/dev/null 2>&1 || die "postconf -n: Postfix configuration is invalid after update"
    postfix check 2>&1 || die "postfix check: Postfix reports a configuration error"
    log "postfix configuration applied and validated"
}

# ---------------------------------------------------------------------------
# OpenDKIM configuration
# ---------------------------------------------------------------------------

# Replace or add a single key=value in opendkim.conf.
# Matches only lines where the key is followed by whitespace or end-of-line,
# anchored at the start (comments stripped), to avoid substring matches.
ensure_opendkim_setting() {
    local key="$1" value="$2"
    local tmp
    tmp=$(mktemp "${OPENDKIM_CONF}.XXXXXX") || die "mktemp failed"
    chmod --reference="$OPENDKIM_CONF" "$tmp" 2>/dev/null || true

    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        # Match: optional leading space/comment, then exactly the key word,
        # then whitespace or end-of-line.  Use word-boundary logic via
        # checking that the character after the key is space/tab or end.
        {
            stripped = $0
            gsub(/^[[:space:]]*#?[[:space:]]*/, "", stripped)
            n = split(stripped, parts, /[[:space:]]+/)
            if (n >= 1 && parts[1] == key && !done) {
                print key "\t\t\t" value
                done = 1
                next
            }
            print
        }
        END { if (!done) print key "\t\t\t" value }
    ' "$OPENDKIM_CONF" > "$tmp" \
        || { rm -f "$tmp"; die "awk failed updating $OPENDKIM_CONF (key=$key)"; }

    cat "$tmp" > "$OPENDKIM_CONF"
    rm -f "$tmp"
}

ensure_line_in_file() {
    local line="$1" file="$2"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

apply_opendkim() {
    [ -f "$OPENDKIM_CONF" ] || die "$OPENDKIM_CONF does not exist; is opendkim installed?"

    getent passwd opendkim >/dev/null 2>&1 \
        || die "OpenDKIM user 'opendkim' not found; install opendkim package first"
    getent group opendkim >/dev/null 2>&1 \
        || die "OpenDKIM group 'opendkim' not found"

    backup_once "$OPENDKIM_CONF" "$OPENDKIM_BACKUP"

    # Create directory structure
    install -d -m 0755 "$OPENDKIM_DIR"
    install -d -o opendkim -g opendkim -m 0750 "${OPENDKIM_DIR}/keys"

    # Create table files if absent (touch preserves existing content)
    [ -f "$KEY_TABLE" ]    || { install -m 0644 /dev/null "$KEY_TABLE";    log "created $KEY_TABLE"; }
    [ -f "$SIGNING_TABLE" ] || { install -m 0644 /dev/null "$SIGNING_TABLE"; log "created $SIGNING_TABLE"; }

    # Apply required settings (idempotent — each replaces/adds its own key)
    # Socket notation: OpenDKIM uses inet:PORT@HOST (reversed from Postfix inet:HOST:PORT)
    ensure_opendkim_setting Mode          "sv"
    ensure_opendkim_setting Socket        "inet:8891@127.0.0.1"
    ensure_opendkim_setting KeyTable      "refile:/etc/opendkim/KeyTable"
    ensure_opendkim_setting SigningTable  "refile:/etc/opendkim/SigningTable"
    ensure_opendkim_setting TrustedHosts  "refile:/etc/opendkim/TrustedHosts"

    # TrustedHosts: create if absent, ensure mandatory entries otherwise
    if [ ! -f "$TRUSTED_HOSTS" ]; then
        cat > "$TRUSTED_HOSTS" << 'EOT'
127.0.0.1
::1
localhost
EOT
        chmod 0644 "$TRUSTED_HOSTS"
        log "created $TRUSTED_HOSTS"
    else
        ensure_line_in_file "127.0.0.1" "$TRUSTED_HOSTS"
        ensure_line_in_file "::1"       "$TRUSTED_HOSTS"
        ensure_line_in_file "localhost" "$TRUSTED_HOSTS"
    fi

    # Fix ownership on table files (conf dir itself is owned by root)
    chown opendkim:opendkim "$KEY_TABLE" "$SIGNING_TABLE" "$TRUSTED_HOSTS"
    chmod 0644 "$KEY_TABLE" "$SIGNING_TABLE" "$TRUSTED_HOSTS"

    log "opendkim configuration applied"
}

# ---------------------------------------------------------------------------
# Service management (only restart/reload services that are already active)
# ---------------------------------------------------------------------------
reload_if_active() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        systemctl reload-or-restart "$svc" \
            && log "reloaded $svc" \
            || warn "reload/restart of $svc failed (check: systemctl status $svc)"
    else
        log "$svc is not running — skipping reload (it will pick up config on next start)"
    fi
}

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------
cmd_apply() {
    require_root
    require_cmds
    log "applying configuration..."
    apply_postfix
    apply_opendkim
    reload_if_active postfix.service
    reload_if_active opendkim.service
    log "done. Run mailserver-validate.sh to verify."
}

cmd_status() {
    require_root
    log "--- Postfix ---"
    postfix check 2>&1 || true
    postconf -n 2>&1   || true
    systemctl --no-pager status postfix.service  || true
    log "--- OpenDKIM ---"
    systemctl --no-pager status opendkim.service || true
    if command -v ss >/dev/null 2>&1; then
        log "--- Listening sockets ---"
        ss -ltnp | grep -E '(8891|SMTP|25|587)' || log "(none matching mail ports)"
    fi
}

case "${1:---apply}" in
    --apply)  cmd_apply  ;;
    --status) cmd_status ;;
    --help|-h)
        echo "Usage: $0 [--apply|--status]"
        echo "  --apply   Apply/refresh Postfix and OpenDKIM configuration (default)"
        echo "  --status  Show current service and configuration status"
        ;;
    *) die "unknown option: $1 (try --help)" ;;
esac
