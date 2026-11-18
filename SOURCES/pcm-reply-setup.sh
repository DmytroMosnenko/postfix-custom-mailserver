#!/bin/bash
# pcm-reply-setup.sh — one-time (idempotent) setup for the pcm-reply tool
# Part of postfix-custom-mailserver RPM.
#
# Makes Postfix keep a private Maildir copy of every message addressed to your
# domains (in addition to the normal alias -> Gmail forwarding), and writes
# /etc/pcm-reply.conf for the pcm-reply tool.
#
# Usage: pcm-reply-setup.sh --gmail YOU@gmail.com [--default-from ADDR] [--name "Display Name"]
#                           [--retention-days N] DOMAIN [DOMAIN...]
#        pcm-reply-setup.sh --from-conf        (used by the RPM %post)
#   Example: pcm-reply-setup.sh --gmail you@gmail.com --default-from support@example.com example.com
#
# --from-conf reads these variables from /etc/postfix-custom-mailserver.conf
# (shell syntax, same file as PCM_CERTBOT_EMAIL) and does nothing if the
# two required ones are missing:
#   PCM_REPLY_GMAIL=you@gmail.com            # required
#   PCM_REPLY_DOMAINS="example.com other.org"  # required, space or comma separated
#   PCM_REPLY_DEFAULT_FROM=support@example.com # optional
#   PCM_REPLY_NAME="Display Name"              # optional
#   PCM_REPLY_RETENTION_DAYS=90                # optional
#
# Re-run with the full argument list to change domains (the conf file is regenerated).
set -uo pipefail

ARCHIVE_USER="pcmreply"
ARCHIVE_HOME="/home/pcmreply"
MAILDIR="${ARCHIVE_HOME}/Maildir"
BCC_MAP="/etc/postfix/pcm_archive_bcc"
CONF="/etc/pcm-reply.conf"

log() { printf '[pcm-reply-setup] %s\n' "$*"; }
die() { printf '[pcm-reply-setup] ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "must be run as root"
command -v postconf >/dev/null 2>&1 || die "postconf not found; is postfix installed?"

GMAIL=""; DEFAULT_FROM=""; NAME=""; RETENTION=90; DOMAINS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --from-conf)
            PCM_CONF="${PCM_CONF:-/etc/postfix-custom-mailserver.conf}"
            if [ -r "$PCM_CONF" ]; then
                # shellcheck disable=SC1090
                . "$PCM_CONF"
            fi
            if [ -z "${PCM_REPLY_GMAIL:-}" ] || [ -z "${PCM_REPLY_DOMAINS:-}" ]; then
                log "PCM_REPLY_GMAIL / PCM_REPLY_DOMAINS not set in ${PCM_CONF} — skipping"
                exit 0
            fi
            GMAIL="$PCM_REPLY_GMAIL"; DEFAULT_FROM="${PCM_REPLY_DEFAULT_FROM:-}"
            NAME="${PCM_REPLY_NAME:-}"; RETENTION="${PCM_REPLY_RETENTION_DAYS:-90}"
            read -r -a DOMAINS <<< "${PCM_REPLY_DOMAINS//,/ }"
            shift ;;
        --retention-days) RETENTION="${2:-}"; shift 2 ;;
        --gmail)        GMAIL="${2:-}"; shift 2 ;;
        --default-from) DEFAULT_FROM="${2:-}"; shift 2 ;;
        --name)         NAME="${2:-}"; shift 2 ;;
        -*)             die "unknown option: $1" ;;
        *)              DOMAINS+=("$1"); shift ;;
    esac
done

[ "${#DOMAINS[@]}" -gt 0 ] || die "give at least one mail domain (e.g. example.com)"
[[ "$GMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "--gmail must be a valid address"
if [ -n "$DEFAULT_FROM" ]; then
    [[ "$DEFAULT_FROM" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "invalid --default-from"
fi
[[ "$NAME" != *$'\n'* ]] || die "invalid --name"
[[ "$RETENTION" =~ ^[0-9]+$ ]] && [ "$RETENTION" -ge 1 ] || die "retention days must be a positive integer"
for d in "${DOMAINS[@]}"; do
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "invalid domain: '$d'"
done

# Don't clobber a recipient_bcc_maps the admin already uses for something else.
current_bcc="$(postconf -h recipient_bcc_maps 2>/dev/null || true)"
case "$current_bcc" in
    ""|"regexp:${BCC_MAP}") ;;
    *) die "recipient_bcc_maps is already set to '${current_bcc}'. Add 'regexp:${BCC_MAP}' to it manually and re-run." ;;
esac

# 1. archive user + Maildir (delivery happens via ~/.forward, so no global home_mailbox change)
if ! getent passwd "$ARCHIVE_USER" >/dev/null; then
    useradd --system --home-dir "$ARCHIVE_HOME" --create-home --shell /sbin/nologin "$ARCHIVE_USER" \
        || die "useradd failed"
    log "created user ${ARCHIVE_USER}"
fi
chmod 0700 "$ARCHIVE_HOME"
install -d -o "$ARCHIVE_USER" -g "$ARCHIVE_USER" -m 0700 "$MAILDIR" "$MAILDIR/cur" "$MAILDIR/new" "$MAILDIR/tmp"
printf '%s/\n' "$MAILDIR" > "${ARCHIVE_HOME}/.forward"      # trailing slash = Maildir delivery
chown "$ARCHIVE_USER:$ARCHIVE_USER" "${ARCHIVE_HOME}/.forward"
chmod 0600 "${ARCHIVE_HOME}/.forward"
# SELinux (AlmaLinux): make sure the files carry the standard home-directory labels
if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "$ARCHIVE_HOME" 2>/dev/null || :
fi

# 2. BCC map: copy every message addressed to one of your domains to the archive user
{
    echo "# Managed by pcm-reply-setup.sh — regenerate by re-running it."
    for d in "${DOMAINS[@]}"; do
        printf '/@%s$/  %s@localhost\n' "${d//./\\.}" "$ARCHIVE_USER"
    done
} > "${BCC_MAP}.tmp" && mv "${BCC_MAP}.tmp" "$BCC_MAP" && chmod 0644 "$BCC_MAP" || die "cannot write $BCC_MAP"

postconf -e "recipient_bcc_maps = regexp:${BCC_MAP}" || die "postconf -e failed"

# 3. tool config
{
    echo "# Generated by pcm-reply-setup.sh"
    echo "[reply]"
    echo "archive_dir  = ${MAILDIR}"
    echo "own_domains  = $(IFS=,; echo "${DOMAINS[*]}")"
    echo "gmail        = ${GMAIL}"
    echo "default_from = ${DEFAULT_FROM}"
    echo "from_name    = ${NAME}"
    echo "retention_days = ${RETENTION}"
} > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF" && chmod 0644 "$CONF" || die "cannot write $CONF"

# 4. apply
postfix check || die "postfix check failed — see output above (nothing reloaded)"
if systemctl is-active --quiet postfix.service; then
    systemctl reload postfix.service && log "postfix reloaded" || log "WARNING: reload failed"
fi

# 5. self-test: is the BCC map right, and can Postfix really deliver into the Maildir?
selftest() {
    local got tag i f
    got="$(postmap -q "probe@${DOMAINS[0]}" "regexp:${BCC_MAP}" 2>/dev/null || true)"
    if [ "$got" = "${ARCHIVE_USER}@localhost" ]; then
        log "self-test: BCC map OK"
    else
        log "WARNING: self-test: BCC map lookup for probe@${DOMAINS[0]} returned '${got}'"
    fi
    if ! systemctl is-active --quiet postfix.service; then
        log "postfix is not running — delivery self-test skipped (re-run this script after starting it)"
        return 0
    fi
    tag="pcm-reply-selftest-$$-$(date +%s)"
    printf 'From: pcm-selftest@localhost\nTo: %s@localhost\nSubject: %s\n\nself-test\n' \
        "$ARCHIVE_USER" "$tag" | "${SENDMAIL:-/usr/sbin/sendmail}" -t -i
    for i in $(seq 1 15); do
        f="$(grep -l -s "^Subject: ${tag}" "$MAILDIR"/new/* "$MAILDIR"/cur/* 2>/dev/null | head -n1)"
        if [ -n "$f" ]; then
            rm -f -- "$f"
            log "self-test: delivery into ${MAILDIR} OK"
            return 0
        fi
        sleep 1
    done
    log "WARNING: self-test message did not reach ${MAILDIR} within 15s."
    log "  Check: postqueue -p ; journalctl -u postfix -n 50 ; ausearch -m avc -ts recent  (SELinux)"
}
selftest

log "done. Mail to ${DOMAINS[*]} is now also archived in ${MAILDIR}"
log "check later with: pcm-reply --list"
