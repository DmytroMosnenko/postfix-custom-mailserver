#!/bin/bash
# mailserver-init-config.sh — interactively create or complete /etc/postfix-custom-mailserver.conf
# Part of postfix-custom-mailserver RPM.
#
# Usage: mailserver-init-config.sh [--reply] [--force] [--check]
#   (default)  ask only for settings that are still missing in the file
#   --reply    ask only for the pcm-reply settings
#   --force    ask again for everything, offering the current values as defaults
#   --check    ask nothing; print the missing required settings, exit 1 if any
#
# Settings written (shell syntax, sourced by the RPM scriptlets and helper scripts):
#   TLS certificate:  PCM_TLS_CERT_NAME, PCM_CERTBOT_EMAIL
#   pcm-reply:        PCM_REPLY_GMAIL, PCM_REPLY_DOMAINS            (required)
#                     PCM_REPLY_DEFAULT_FROM, PCM_REPLY_NAME,
#                     PCM_REPLY_RETENTION_DAYS                      (optional)
# Other lines already in the file are left untouched.
set -u

CONF="${PCM_CONF:-/etc/postfix-custom-mailserver.conf}"
FORCE=0; ONLY_REPLY=0; CHECK=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --reply) ONLY_REPLY=1 ;;
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "ERROR: unknown option: $arg" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

PCM_TLS_CERT_NAME=""; PCM_CERTBOT_EMAIL=""
PCM_REPLY_GMAIL=""; PCM_REPLY_DOMAINS=""; PCM_REPLY_DEFAULT_FROM=""; PCM_REPLY_NAME=""; PCM_REPLY_RETENTION_DAYS=""
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# ── what is missing? ─────────────────────────────────────────────────────────
missing=""
[ "$ONLY_REPLY" -eq 1 ] || [ -n "$PCM_CERTBOT_EMAIL" ] || missing="$missing PCM_CERTBOT_EMAIL"
[ -n "$PCM_REPLY_GMAIL" ]   || missing="$missing PCM_REPLY_GMAIL"
[ -n "$PCM_REPLY_DOMAINS" ] || missing="$missing PCM_REPLY_DOMAINS"

if [ "$CHECK" -eq 1 ]; then
    [ -z "$missing" ] && exit 0
    echo "$missing"
    exit 1
fi

do_tls=0; do_reply=0
if [ "$FORCE" -eq 1 ]; then
    [ "$ONLY_REPLY" -eq 1 ] || do_tls=1
    do_reply=1
else
    case "$missing" in *PCM_CERTBOT_EMAIL*) do_tls=1 ;; esac
    case "$missing" in *PCM_REPLY_*) do_reply=1 ;; esac
fi

if [ "$do_tls" -eq 0 ] && [ "$do_reply" -eq 0 ]; then
    echo "[postfix-custom-mailserver] $CONF is already complete (use --force to change it)"
    exit 0
fi

if [ ! -t 0 ]; then
    echo "ERROR: no terminal attached; edit $CONF manually (see README) — missing:${missing:- (--force given)}" >&2
    exit 1
fi

# ── helpers ──────────────────────────────────────────────────────────────────
ANS=""
# ask PROMPT DEFAULT REGEX REQUIRED(1|0) -> ANS
ask() {
    local prompt="$1" def="$2" re="$3" req="$4" v
    while :; do
        read -r -p "${prompt}${def:+ [$def]}: " v || { echo; exit 1; }
        v="${v:-$def}"
        if [ -z "$v" ]; then
            [ "$req" = 1 ] || { ANS=""; return 0; }
            echo "  A value is required"; continue
        fi
        if [[ "$v" =~ $re ]]; then ANS="$v"; return 0; fi
        echo "  Invalid value"
    done
}

shquote() {   # plain when safe, otherwise 'single quoted'
    if [[ "$1" =~ ^[A-Za-z0-9@._,:/+-]+$ ]]; then printf '%s' "$1"
    else printf "'%s'" "${1//\'/\'\\\'\'}"; fi
}

# set_var KEY VALUE — replaces the KEY= line; an empty VALUE just removes it
set_var() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp)" || return 1
    { grep -v "^${key}=" "$CONF" 2>/dev/null || :; [ -z "$val" ] || printf '%s=%s\n' "$key" "$(shquote "$val")"; } > "$tmp"
    cat "$tmp" > "$CONF"; rm -f "$tmp"
}

[ -e "$CONF" ] || { ( umask 077; : > "$CONF" ) || { echo "ERROR: cannot create $CONF" >&2; exit 1; }; }
chown root:root "$CONF" 2>/dev/null || :

EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'

# ── TLS certificate ──────────────────────────────────────────────────────────
if [ "$do_tls" -eq 1 ]; then
    echo
    echo "TLS certificate setup (Let's Encrypt) — values are saved to $CONF"
    default_host="${PCM_TLS_CERT_NAME:-$(postconf -h myhostname 2>/dev/null || true)}"
    case "$default_host" in *.*) ;; *) default_host="" ;; esac
    ask "Mail server hostname (FQDN)" "$default_host" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$' 1
    set_var PCM_TLS_CERT_NAME "$ANS"
    ask "Contact email for Let's Encrypt notices" "$PCM_CERTBOT_EMAIL" "$EMAIL_RE" 1
    set_var PCM_CERTBOT_EMAIL "$ANS"
fi

# ── pcm-reply ────────────────────────────────────────────────────────────────
if [ "$do_reply" -eq 1 ]; then
    echo
    echo "pcm-reply setup (reply-all from this server) — values are saved to $CONF"
    ask "Your real mailbox that the aliases forward to (e.g. you@gmail.com)" "$PCM_REPLY_GMAIL" "$EMAIL_RE" 1
    set_var PCM_REPLY_GMAIL "$ANS"

    def_domains="${PCM_REPLY_DOMAINS:-$(ls -1 /etc/opendkim/keys 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')}"
    while :; do
        ask "Mail domains to archive and reply from (space separated)" "$def_domains" '^[A-Za-z0-9., -]+$' 1
        ok=1
        for d in ${ANS//,/ }; do [[ "$d" =~ $DOMAIN_RE ]] || { echo "  Invalid domain: $d"; ok=0; }; done
        [ "$ok" -eq 1 ] && break
    done
    # shellcheck disable=SC2086
    set_var PCM_REPLY_DOMAINS "$(echo ${ANS//,/ })"     # normalise separators/spaces

    ask "Default From address, used when the mail was Bcc'd to you (optional, Enter to skip)" "$PCM_REPLY_DEFAULT_FROM" "$EMAIL_RE" 0
    set_var PCM_REPLY_DEFAULT_FROM "$ANS"
    ask "Display name on replies (optional, Enter to skip)" "$PCM_REPLY_NAME" '^[^[:cntrl:]]+$' 0
    set_var PCM_REPLY_NAME "$ANS"
    ask "Keep archived mail for how many days" "${PCM_REPLY_RETENTION_DAYS:-90}" '^[1-9][0-9]*$' 1
    set_var PCM_REPLY_RETENTION_DAYS "$ANS"
fi

echo "[postfix-custom-mailserver] wrote $CONF"
