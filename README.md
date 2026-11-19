# postfix-custom-mailserver

Private RPM package for configuring Postfix as an outbound-only SMTP relay
for application mail, with OpenDKIM signing.

**Target platforms:** Amazon Linux 2023, AlmaLinux 8/9, RHEL 8/9+

---

## What this package does

Installs helper scripts under `/usr/libexec/postfix-custom-mailserver/`, plus the
`pcm-reply` tool in `/usr/bin` (see [Replying from the server](#replying-from-the-server-pcm-reply)):

| Script | Purpose |
|---|---|
| `mailserver-configure.sh` | Apply/refresh Postfix + OpenDKIM config (idempotent) |
| `generate-dkim-key.sh` | Generate DKIM keys and register them |
| `add-alias.sh` | Safely add `/etc/aliases` entries |
| `mailserver-validate.sh` | Full health check with colored output |
| `mailserver-preinstall-check.sh` | Diagnose existing state before install |
| `mailserver-init-config.sh` | Interactively create/complete `/etc/postfix-custom-mailserver.conf` (TLS + pcm-reply settings) |
| `pcm-reply-setup.sh` | Enable the server-side mail archive used by `pcm-reply` |
| `/usr/bin/pcm-reply` | Reply-all from the server to mail that arrived through an alias |
| `pcm-reply-prune.timer` | Daily pruning of the archive (systemd timer, not a script) |

After install, the `%post` scriptlet runs `mailserver-configure.sh --apply`
automatically.

### What it configures

**Postfix `main.cf`** — inserts a clearly-marked managed block:
```
inet_interfaces        = loopback-only   # only localhost relays (safe)
inet_protocols         = all
mynetworks             = 127.0.0.0/8, [::1]/128
alias_maps             = hash:/etc/aliases
alias_database         = hash:/etc/aliases
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
milter_default_action  = accept
milter_protocol        = 6
smtpd_milters          = inet:127.0.0.1:8891
non_smtpd_milters      = inet:127.0.0.1:8891
```

Everything outside the marked block is **preserved**.

**OpenDKIM `opendkim.conf`** — sets/replaces individual keys:
- `Mode sv`
- `Socket inet:8891@127.0.0.1`
- `KeyTable refile:/etc/opendkim/KeyTable`
- `SigningTable refile:/etc/opendkim/SigningTable`
- `TrustedHosts refile:/etc/opendkim/TrustedHosts`

---

## Full setup walkthrough

### 1. Install the RPM

```bash
# On an existing messy server — check state first (read-only):
sudo /usr/libexec/postfix-custom-mailserver/mailserver-preinstall-check.sh

# Install or upgrade:
sudo dnf install ./postfix-custom-mailserver-3.3-1.noarch.rpm
```

### 2. Set your server's hostname (important for DKIM)

The `From` domain in your mail must match the DKIM signing domain.
Make sure Postfix knows your domain:

```bash
# Check current hostname:
hostname -f

# If it's wrong or generic, set it:
sudo hostnamectl set-hostname mail.yourdomain.com

# Tell Postfix explicitly (add BELOW the managed block in main.cf):
# myhostname = mail.yourdomain.com
# mydomain   = yourdomain.com
# myorigin   = $mydomain
```

#### TLS certificate (Let's Encrypt)

The RPM requests a certificate for your Postfix `myhostname` (must be an FQDN) and
points Postfix at it. Without it, Postfix serves the self-signed dummy cert created
by the postfix package. Before installing, create `/etc/postfix-custom-mailserver.conf`
(root-owned, sourced as shell). On an interactive install the RPM offers to create it
for you (and also asks for the `pcm-reply` settings, see below); otherwise run
`/usr/libexec/postfix-custom-mailserver/mailserver-init-config.sh`:

```bash
PCM_CERTBOT_EMAIL=admin@yourdomain.com   # required for certbot
# PCM_TLS_CERT_NAME=mail.yourdomain.com  # optional; defaults to myhostname
```

If the file is absent the certbot step is skipped. Re-run
`mailserver-configure.sh --apply` after the cert exists.

### 3. Generate DKIM key

```bash
sudo /usr/libexec/postfix-custom-mailserver/generate-dkim-key.sh yourdomain.com
```

This will print a DNS TXT record. Add it to your domain's DNS zone.

### 4. Add email aliases

```bash
# Forward root mail to an external address:
sudo /usr/libexec/postfix-custom-mailserver/add-alias.sh root you@gmail.com

# Forward a virtual user used by your app:
sudo /usr/libexec/postfix-custom-mailserver/add-alias.sh noreply you@gmail.com
```

### 5. Validate

```bash
sudo /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh
```

### 6. Test

```bash
echo "Test from $(hostname -f) at $(date)" | mail -s "Mail server test" you@gmail.com
```

Wait a few minutes and check your inbox (and spam folder).

### 7. Verify DKIM after DNS propagation

```bash
opendkim-testkey -d yourdomain.com -s mail -vvv
```

---

## DNS records you need

Add all three to your domain's DNS zone:

```
# DKIM (printed by generate-dkim-key.sh):
mail._domainkey.yourdomain.com  TXT  "v=DKIM1; k=rsa; p=<public key>"

# SPF (allow your server's IP to send mail):
yourdomain.com  TXT  "v=spf1 a mx ip4:YOUR_SERVER_IP ~all"

# DMARC (start permissive, tighten later):
_dmarc.yourdomain.com  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@yourdomain.com"
```

---

## Replying from the server (pcm-reply)

Aliases forward incoming mail to your Gmail, so the server itself has no copy of it.
`pcm-reply` fixes that: Postfix keeps a private Maildir copy of everything addressed
to your domains, and `pcm-reply` finds the original there, builds a proper **reply-all**
and sends it through the local `sendmail` (so OpenDKIM signs it like any other mail).
You only give it a hint (id, subject or sender) and your text.

### Setup

All `pcm-reply` settings live in `/etc/postfix-custom-mailserver.conf`, next to the TLS settings:

| Variable | Required | What it is used for |
|---|---|---|
| `PCM_REPLY_GMAIL` | yes | Your real mailbox (the alias target). Removed from reply-all recipients, and gets a Bcc copy of every reply so it shows up threaded in your inbox. |
| `PCM_REPLY_DOMAINS` | yes | Your mail domains (space separated). Mail addressed to them is archived on the server; addresses in these domains count as "you" (removed from recipients, and used as the From of replies). |
| `PCM_REPLY_DEFAULT_FROM` | no | From address when no own-domain address is in To/Cc (mail that reached you by Bcc). |
| `PCM_REPLY_NAME` | no | Display name on replies. |
| `PCM_REPLY_RETENTION_DAYS` | no | How long archived mail is kept (default 90). |

**During `dnf install`** (from an interactive terminal; dnf redirects scriptlet input and output, so the
questions are asked on the controlling terminal, `/dev/tty`) the installer asks for whatever is still missing
via `mailserver-init-config.sh` — it only asks the TLS questions if the cert settings are missing,
and only the `pcm-reply` questions if those are missing, so an upgrade of an already configured
server asks nothing. It then runs `pcm-reply-setup.sh --from-conf`.

On a **non-interactive install** (Ansible, cloud-init, `ssh host dnf install` without `-t`, or with
`PCM_NONINTERACTIVE=1` set) nothing can be asked.
The installer then prints which settings are missing and the commands to finish:

```bash
sudo /usr/libexec/postfix-custom-mailserver/mailserver-init-config.sh --reply   # asks only the pcm-reply questions
sudo /usr/libexec/postfix-custom-mailserver/pcm-reply-setup.sh --from-conf      # applies them
```

You can also edit the file by hand (shell syntax) instead of answering questions:

```bash
PCM_REPLY_GMAIL=you@gmail.com
PCM_REPLY_DOMAINS="yourdomain.com other.org"
# PCM_REPLY_DEFAULT_FROM=support@yourdomain.com
# PCM_REPLY_NAME="Your Name"
# PCM_REPLY_RETENTION_DAYS=90
```

`mailserver-init-config.sh --check` lists missing settings without asking anything,
`--force` asks everything again (current values are offered as defaults).
`pcm-reply-setup.sh` can also be run with explicit arguments, without the conf file:

```bash
sudo /usr/libexec/postfix-custom-mailserver/pcm-reply-setup.sh \
    --gmail you@gmail.com --default-from support@yourdomain.com yourdomain.com
```

The script is idempotent. It creates the system user `pcmreply` (home `/home/pcmreply`,
Maildir inside, mode 0700), sets `recipient_bcc_maps = regexp:/etc/postfix/pcm_archive_bcc`
in `main.cf`, writes `/etc/pcm-reply.conf`, reloads Postfix and runs a delivery self-test.
It refuses to overwrite a `recipient_bcc_maps` you already use for something else.

### Usage

Run as root, or as the archive user (`sudo -u pcmreply pcm-reply ...`).

```bash
pcm-reply --list                          # archived messages, newest first, with 8-char ids
pcm-reply --show 787a2d52                 # read a message: headers, attachment names, decoded text
pcm-reply --delete 787a2d52               # remove a message from the archive (asks first; -y to skip)
pcm-reply --delete from:spam@ --all -y    # remove every match
pcm-reply --import old.eml                # add a message that arrived before setup (see below)
pcm-reply --show "invoice" --latest --raw # full raw source (all headers)
pcm-reply "invoice 2043" -m "Paid today, thanks."
pcm-reply from:john --latest --body-file reply.txt
echo "Thanks!" | pcm-reply 787a2d52       # body from stdin
pcm-reply "invoice" -m "..." --dry-run    # print the reply, do not send
```

**SELECTOR** is an 8-char id from `--list`, a full Message-ID, a piece of the subject, or
`from:<piece of the sender>` (a bare word that matches no subject falls back to sender
search). If several messages match, `pcm-reply` lists them and exits with status 2 instead
of guessing; use an id or `--latest` (newest match).

| Option | Meaning |
|---|---|
| `-m TEXT`, `--body-file FILE` | Reply text (or pipe it on stdin; `--body-file -` = stdin) |
| `--list [SELECTOR] [-n N]` | List archived messages instead of replying |
| `--delete SELECTOR` | Delete the selected message from the archive after confirmation (several matches need an id, `--latest`, or `--all`) |
| `--all`, `-y` / `--yes` | With `--delete`: delete every match / skip the confirmation (required without a terminal) |
| `--import FILE` | Add a raw message (`.eml`, or `-` for stdin) to the archive and exit |
| `--show SELECTOR [--raw]` | Print the selected message (decoded text and attachment names; `--raw` = raw source) instead of replying |
| `--latest` | If several messages match, use the newest |
| `--from ADDR` | Send as this address (default: the alias the mail was sent to) |
| `--no-quote` | Do not quote the original message |
| `--no-copy` | Do not Bcc a copy to your Gmail |
| `--dry-run` | Print the reply and envelope, send nothing |
| `--prune [DAYS]` | Delete archived mail older than DAYS (default: `retention_days`) and exit |

**What a reply looks like**

- **To:** original Reply-To (else From) plus the original To; **Cc:** the original Cc. Your own-domain
  addresses and your Gmail are removed. If nobody is left (e.g. a contact form that sends *from* your
  own domain without Reply-To), it stops with an error.
- **From:** the own-domain address the mail was sent to (`--from` overrides, `default_from` is the fallback).
- **Subject / threading:** `Re: ...`, with `In-Reply-To` and `References` set, so Gmail and the
  recipients thread it correctly.
- **Gmail copy:** a Bcc (envelope only) to `gmail`, so the reply shows up in your inbox in the same thread.

### Replying to mail received before setup

Mail that arrived before the archive existed is only in Gmail. Export it from there and import it:

1. In Gmail open the message, **⋮ → Show original → Download original** (an `.eml` file). Do this on the
   message you want to answer, not on your own earlier reply.
2. Copy it to the server and import it:
   ```bash
   scp ~/Downloads/original.eml server:/tmp/
   sudo pcm-reply --import /tmp/original.eml      # prints the new id; a message already archived is detected
   # or paste it directly: sudo pcm-reply --import -   (paste, then Ctrl-D)
   ```
3. Reply as usual: `sudo pcm-reply <id> -m "..."` (check first with `--show <id>` or `--dry-run`).

The imported copy is stamped with the import time, not the mail's date, so the prune timer keeps it for the full
retention period. Delete the `.eml` from `/tmp` afterwards.

### Configuration: `/etc/pcm-reply.conf`

Generated by `pcm-reply-setup.sh` (re-run it to change values):

```ini
[reply]
archive_dir    = /home/pcmreply/Maildir
own_domains    = yourdomain.com,other.org
gmail          = you@gmail.com
default_from   = support@yourdomain.com
from_name      = Your Name
retention_days = 90
```

### Archive retention

`pcm-reply-prune.timer` runs `pcm-reply --prune` daily (as `pcmreply`, sandboxed) and deletes
archived mail older than `retention_days`. It is enabled by the package; the service does nothing
until the archive exists.

```bash
systemctl list-timers pcm-reply-prune.timer
systemctl start pcm-reply-prune.service   # run now
journalctl -u pcm-reply-prune.service
```

### Notes and limitations

- Only mail received **after** setup can be replied to; older mail exists only in Gmail.
- The archive holds a copy of *all* incoming mail for the configured domains (spam included),
  readable only by root and `pcmreply`. Keep `retention_days` as short as you can live with.
- If the archive mailbox cannot accept mail (disk full, wrong permissions, SELinux denial), Postfix
  bounces that copy to the sender even though the Gmail forward still works. If `pcm-reply-setup.sh`
  reports that the self-test message did not arrive, check `postqueue -p`, `journalctl -u postfix`
  and `ausearch -m avc -ts recent`.
- Removing the package unsets `recipient_bcc_maps` (if it still has the pcm-reply value) so the archive
  stops growing. `/home/pcmreply` and `/etc/pcm-reply.conf` are left in place; delete them by hand
  if you want the archived mail gone.
- `--delete` only removes the server's archive copy; the mail in Gmail is untouched.
- Requires Python 3.6+ (standard library only).

---

## Installing over an existing broken setup

The package is designed to be installed directly over a broken previous
installation. The configure script:

1. **Never appends** — it uses a marked block that it replaces atomically.
2. **Backs up first** — `main.cf.pcm-orig` and `opendkim.conf.pcm-orig` are
   created once and never overwritten.
3. **Validates before restarting** — runs `postfix check` before touching
   the running service.
4. **Preserves DKIM keys** — keys in `/etc/opendkim/keys/` are never removed.

If the old install had duplicate `inet_interfaces` or `smtpd_milters` lines
in `main.cf` (from naive appending), `postconf` will use the last occurrence.
The managed block goes at the end and wins. But for a clean state, remove the
duplicates manually (the preinstall-check script will identify them).

---

## Building the RPM

```bash
# Clone the repository
git clone https://github.com/DmytroMosnenko/postfix-custom-mailserver
cd postfix-custom-mailserver

# Install build dependencies
sudo dnf install -y rpm-build rpmdevtools systemd-rpm-macros

# Set up rpmbuild tree
rpmdev-setuptree

# Create the source tarball
VERSION=3.3
tar -czf ~/rpmbuild/SOURCES/postfix-custom-mailserver-${VERSION}.tar.gz \
    --exclude='.git' \
    --exclude='.github' \
    --transform="s|^|postfix-custom-mailserver-${VERSION}/|" \
    SPECS/ SOURCES/ README.md LICENSE

# Copy spec
cp SPECS/postfix-custom-mailserver.spec ~/rpmbuild/SPECS/

# Build
rpmbuild -ba ~/rpmbuild/SPECS/postfix-custom-mailserver.spec

# The RPM will be in:
ls ~/rpmbuild/RPMS/noarch/
```

Or use the GitHub Actions workflow (push a `v3.3` tag).
