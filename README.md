# postfix-custom-mailserver 2.0

Private RPM for configuring Postfix + OpenDKIM for application mail delivery on RPM-based Linux systems.

## Design goals

- Idempotent install and upgrade.
- Preserve administrator configuration outside package-managed blocks.
- Never overwrite an existing OpenDKIM `TrustedHosts` file.
- Never regenerate an existing DKIM private key.
- Never stop a service that was already stopped.
- Never start a service merely because the RPM was installed.
- Explicitly configure the OpenDKIM TCP socket used by Postfix.
- Keep runtime state and private keys outside RPM-owned files.
- Package removal removes only the helper programs, not mail-server configuration or keys.

## Installation

```bash
sudo dnf install ./postfix-custom-mailserver-2.0-1*.rpm
```

The package applies its managed configuration block and enables Postfix/OpenDKIM for boot. If a service was already running, configuration is reloaded/restarted after validation. A stopped service remains stopped.

## Validate

```bash
sudo /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh
```

## Add a domain / generate DKIM

```bash
sudo /usr/libexec/postfix-custom-mailserver/generate-dkim-key.sh example.com
```

The command prints the DNS TXT record. Do not regenerate a key just because DNS has not propagated.

## Add an alias

```bash
sudo /usr/libexec/postfix-custom-mailserver/add-alias.sh admin destination@example.com
```

Existing aliases are never silently replaced.

## Managed configuration

Postfix receives a clearly delimited block in `/etc/postfix/main.cf`:

```text
# BEGIN postfix-custom-mailserver
...
# END postfix-custom-mailserver
```

OpenDKIM settings are updated by key rather than by appending duplicate settings.

A one-time backup is kept at:

- `/etc/postfix/main.cf.postfix-custom-mailserver.orig`
- `/etc/opendkim.conf.postfix-custom-mailserver.orig`

These backups are intentionally not removed on RPM erase.

## Upgrade behavior

Repeated installs/upgrades are safe. The Postfix managed block is replaced rather than appended repeatedly. Existing administrator settings outside the block are preserved.

## Important operational note

This package assumes the operating system's Postfix and OpenDKIM packages are already correctly packaged for the target distribution. In particular, OpenDKIM must provide the `opendkim` user/group and `opendkim-genkey` utility.
