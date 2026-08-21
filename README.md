# postfix-custom-mailserver

Private RPM package for configuring Postfix as an outbound-only SMTP relay
for application mail, with OpenDKIM signing.

**Target platforms:** Amazon Linux 2023, AlmaLinux 8/9, RHEL 8/9+

---

## What this package does

Installs five helper scripts under `/usr/libexec/postfix-custom-mailserver/`:

| Script | Purpose |
|---|---|
| `mailserver-configure.sh` | Apply/refresh Postfix + OpenDKIM config (idempotent) |
| `generate-dkim-key.sh` | Generate DKIM keys and register them |
| `add-alias.sh` | Safely add `/etc/aliases` entries |
| `mailserver-validate.sh` | Full health check with colored output |
| `mailserver-preinstall-check.sh` | Diagnose existing state before install |

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
smtpd_relay_restrictions = permit_mynetworks, reject   # no open relay
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
sudo dnf install ./postfix-custom-mailserver-3.0-1.noarch.rpm
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
VERSION=3.0
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

Or use the GitHub Actions workflow (push a `v3.0` tag).
