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

# The parameters we own. Any uncommented line setting one of these in the
# upstream default main.cf will conflict with our managed block and produce
# "overriding earlier entry" warnings on every postfix invocation.
# We comment them out (not delete them, so the original intent is readable)
# before inserting our block.
readonly -a MANAGED_PARAMS=(
    inet_interfaces
    inet_protocols
    mynetworks
    alias_maps
    alias_database
    smtpd_relay_restrictions
    milter_default_action
    milter_protocol
    smtpd_milters
    non_smtpd_milters
)

# Comment out any bare (uncommented) occurrence of $key = ... that lives
# OUTSIDE our managed block. Called before replace_managed_block so the
# file is clean before we append/replace.
comment_out_upstream_params() {
    local file="$1"
    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || die "mktemp failed"
    chmod --reference="$file" "$tmp" 2>/dev/null || true

    # Build an awk pattern that matches any of the managed param names
    # as the first word on an uncommented line, outside our block.
    local pattern
    pattern=$(printf '%s|' "${MANAGED_PARAMS[@]}")
    pattern="${pattern%|}"   # strip trailing pipe

    awk \
        -v block_start="$BLOCK_START" \
        -v block_end="$BLOCK_END" \
        -v pattern="$pattern" '
        BEGIN { in_block=0 }
        $0 == block_start { in_block=1; print; next }
        $0 == block_end   { in_block=0; print; next }
        in_block          { print; next }
        # Outside the block: comment out uncommented lines whose first
        # non-space token exactly matches one of our managed params.
        {
            line = $0
            # Skip blank lines and already-commented lines
            if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) {
                print line; next
            }
            # Extract first token
            key = line
            gsub(/^[[:space:]]+/, "", key)
            split(key, parts, /[[:space:]]*=|[[:space:]]+/)
            key = parts[1]
            # Check against managed params
            n = split(pattern, plist, /\|/)
            matched = 0
            for (i = 1; i <= n; i++) {
                if (key == plist[i]) { matched=1; break }
            }
            if (matched) {
                print "# [pcm-managed] " line
            } else {
                print line
            }
        }
    ' "$file" > "$tmp" \
        || { rm -f "$tmp"; die "awk failed commenting out upstream params in $file"; }

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

apply_postfix() {
    [ -f "$POSTFIX_MAIN_CF" ] || die "$POSTFIX_MAIN_CF does not exist; is postfix installed?"
    backup_once "$POSTFIX_MAIN_CF" "$POSTFIX_BACKUP"

    # Detect which alias map type this postfix build supports.
    # AlmaLinux/RHEL 9+ ships postfix without postfix-hash; uses lmdb.
    # Amazon Linux 2023 ships with hash support. Probe postconf -m.
    local alias_map_type="lmdb"
    if postconf -m 2>/dev/null | grep -qx "lmdb"; then
        alias_map_type="lmdb"
    elif postconf -m 2>/dev/null | grep -qx "hash"; then
        alias_map_type="hash"
    else
        # Last resort: read what the distro already configured
        local existing
        existing=$(grep -E "^alias_maps[[:space:]]*=" "$POSTFIX_MAIN_CF" 2>/dev/null | head -1 | grep -oP '\w+(?=:)' | head -1)
        alias_map_type="${existing:-lmdb}"
        warn "could not detect map type via postconf -m; falling back to '$alias_map_type'"
    fi
    log "using alias map type: $alias_map_type"

    # Step 1: comment out any conflicting upstream defaults (outside our block)
    comment_out_upstream_params "$POSTFIX_MAIN_CF"

    local block
    block=$(mktemp) || die "mktemp failed"

    # NOTE: the heredoc delimiter is NOT quoted here so $alias_map_type expands.
    # inet_interfaces = loopback-only: only localhost can relay (Python apps,
    # cron, etc.). NOT "all" — that would open an external SMTP listener.
    # smtpd_relay_restrictions: hard-blocks relaying for non-mynetworks hosts.
    # non_smtpd_milters: signs mail injected via sendmail/pickup (local apps).
    cat > "$block" << EOB
# BEGIN postfix-custom-mailserver
# Managed by postfix-custom-mailserver RPM. Do not edit between these markers.
# To override, add settings BELOW this block.
inet_interfaces          = loopback-only
inet_protocols           = all
mynetworks               = 127.0.0.0/8, [::1]/128
alias_maps               = ${alias_map_type}:/etc/aliases
alias_database           = ${alias_map_type}:/etc/aliases
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
milter_default_action    = accept
milter_protocol          = 6
smtpd_milters            = inet:127.0.0.1:8891
non_smtpd_milters        = inet:127.0.0.1:8891
# END postfix-custom-mailserver
EOB

    replace_managed_block "$POSTFIX_MAIN_CF" "$block"
    rm -f "$block"

    postconf -n >/dev/null 2>&1 || die "postconf -n: Postfix configuration is invalid after update"
    postfix check 2>/dev/null   || die "postfix check: Postfix reports a configuration error"
    log "postfix configuration applied and validated"
}

# ---------------------------------------------------------------------------
# OpenDKIM configuration
# ---------------------------------------------------------------------------

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

    # Create table files if absent (never overwrite existing ones — they hold
    # the admin's domain entries).
    [ -f "$KEY_TABLE" ]     || { install -o opendkim -g opendkim -m 0644 /dev/null "$KEY_TABLE";     log "created $KEY_TABLE"; }
    [ -f "$SIGNING_TABLE" ] || { install -o opendkim -g opendkim -m 0644 /dev/null "$SIGNING_TABLE"; log "created $SIGNING_TABLE"; }

    # TrustedHosts: create if absent, append mandatory loopback entries otherwise
    if [ ! -f "$TRUSTED_HOSTS" ]; then
        cat > "$TRUSTED_HOSTS" << 'EOT'
127.0.0.1
::1
localhost
EOT
        chown opendkim:opendkim "$TRUSTED_HOSTS"
        chmod 0644 "$TRUSTED_HOSTS"
        log "created $TRUSTED_HOSTS"
    else
        ensure_line_in_file "127.0.0.1" "$TRUSTED_HOSTS"
        ensure_line_in_file "::1"       "$TRUSTED_HOSTS"
        ensure_line_in_file "localhost" "$TRUSTED_HOSTS"
    fi

    # Comment out every active (non-comment, non-blank) line in opendkim.conf
    # that lives OUTSIDE our managed block. The stock conf from the package has
    # many active settings (Socket, Mode, TrustedHosts, etc.) that conflict with
    # or duplicate our block -- including parameters unrecognized in opendkim 2.11
    # (e.g. TrustedHosts) that cause EX_CONFIG / exit 78.
    # After this pass the original content is preserved as comments for reference;
    # our managed block becomes the single authoritative source.
    local tmp_conf
    tmp_conf=$(mktemp "${OPENDKIM_CONF}.XXXXXX") || die "mktemp failed"
    chmod --reference="$OPENDKIM_CONF" "$tmp_conf" 2>/dev/null || true

    awk \
        -v block_start="$BLOCK_START" \
        -v block_end="$BLOCK_END" '
        BEGIN { in_block=0 }
        $0 == block_start { in_block=1; print; next }
        $0 == block_end   { in_block=0; print; next }
        in_block          { print; next }
        /^[[:space:]]*$/  { print; next }
        /^[[:space:]]*#/  { print; next }
        { print "## [pcm] " $0 }
    ' "$OPENDKIM_CONF" > "$tmp_conf" \
        || { rm -f "$tmp_conf"; die "awk failed neutralising opendkim.conf"; }

    cat "$tmp_conf" > "$OPENDKIM_CONF"
    rm -f "$tmp_conf"

    # Write the managed block. All operational settings live here.
    # Socket: OpenDKIM uses inet:PORT@HOST (reversed vs Postfix inet:HOST:PORT)
    # PidFile omitted: /run/opendkim is created by the systemd RuntimeDirectory=
    # directive on modern distros; we let the unit handle it.
    local block
    block=$(mktemp) || die "mktemp failed"
    cat > "$block" << 'ODKIM_BLOCK'
# BEGIN postfix-custom-mailserver
# Managed by postfix-custom-mailserver RPM. Do not edit between these markers.
# All operational settings live here; lines above are neutralised for reference.
Mode                    sv
Socket                  inet:8891@127.0.0.1
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes
UserID                  opendkim:opendkim
UMask                   007
Canonicalization        relaxed/relaxed
OversignHeaders         From
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
# END postfix-custom-mailserver
ODKIM_BLOCK

    replace_managed_block "$OPENDKIM_CONF" "$block"
    rm -f "$block"

    # Fix ownership on table files
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
