# postfix-custom-mailserver

RPM packaging for a Postfix + OpenDKIM mail-server integration on RPM-based Linux systems.

## Targets

The package is built on Amazon Linux 2023 and is intended for:

- Amazon Linux 2023
- AlmaLinux 9

The package is `noarch`; it contains shell scripts and configuration logic rather than compiled binaries.

## What the RPM does

The RPM installs administrative helpers under:

```text
/usr/libexec/postfix-custom-mailserver/
```

It also applies a managed Postfix/OpenDKIM configuration during installation and upgrade.

The configuration is designed to be idempotent:

- repeated installation does not append duplicate Postfix settings;
- existing administrator configuration outside the managed block is preserved;
- existing OpenDKIM `TrustedHosts` entries are preserved;
- existing DKIM keys are never silently replaced;
- package removal does not stop or disable the mail services;
- package removal does not delete mail-server configuration or DKIM keys.

## Versioning

The repository keeps a neutral RPM version in the spec file:

```spec
Version: 0.0.0
```

The GitHub Actions workflow replaces this value with the Git tag version.

For example:

```bash
git tag v2.1.0
git push origin v2.1.0
```

builds:

```text
postfix-custom-mailserver-2.1.0-1.*.noarch.rpm
postfix-custom-mailserver-2.1.0-1.src.rpm
```

The Git tag is therefore the authoritative application/package version.

## Build locally

On an RPM-based build host:

```bash
sudo dnf install rpm-build rpmdevtools systemd-rpm-macros tar gzip
rpmdev-setuptree
```

Create a source archive whose top-level directory is:

```text
postfix-custom-mailserver-VERSION/
```

and contains `SOURCES/`, `README.md`, and `LICENSE`.

Then copy the archive to `~/rpmbuild/SOURCES/`, copy the spec to `~/rpmbuild/SPECS/`, set the desired `Version:` in the spec, and run:

```bash
rpmbuild -ba ~/rpmbuild/SPECS/postfix-custom-mailserver.spec
```

The GitHub workflow performs these steps automatically from a release tag.

## Release

Push a tag using the format:

```text
vMAJOR.MINOR.PATCH
```

For example:

```bash
git tag v2.1.0
git push origin v2.1.0
```

The workflow builds the RPM and SRPM in an Amazon Linux 2023 container and attaches both to the GitHub Release.

## Administration helpers

Configure or re-apply the managed configuration:

```bash
sudo /usr/libexec/postfix-custom-mailserver/mailserver-configure.sh --apply
```

Show service status:

```bash
sudo /usr/libexec/postfix-custom-mailserver/mailserver-configure.sh --status
```

Validate the installation:

```bash
sudo /usr/libexec/postfix-custom-mailserver/mailserver-validate.sh
```

Generate a DKIM key:

```bash
sudo /usr/libexec/postfix-custom-mailserver/generate-dkim-key.sh example.com
```

Add a local alias:

```bash
sudo /usr/libexec/postfix-custom-mailserver/add-alias.sh admin admin@example.com
```

## Important

The RPM expects the required Postfix/OpenDKIM packages to be available from the configured repositories. Package availability can differ between distributions and repository configurations.

The RPM intentionally does not contain a DKIM private key. DKIM keys are generated on the target server and remain outside the RPM payload.
