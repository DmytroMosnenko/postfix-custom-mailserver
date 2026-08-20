# RPM build and release

## Repository layout

```text
.
├── .github/
│   └── workflows/
│       └── build-rpm.yml
├── SOURCES/
│   ├── add-alias.sh
│   ├── generate-dkim-key.sh
│   ├── mailserver-configure.sh
│   └── mailserver-validate.sh
├── SPECS/
│   └── postfix-custom-mailserver.spec
├── .gitignore
├── build.md
├── LICENSE
└── README.md
```

## Release build

The GitHub Actions workflow is triggered by a tag matching:

```text
v*
```

Use a numeric semantic-style version:

```bash
git tag v2.1.0
git push origin v2.1.0
```

The workflow converts `v2.1.0` into RPM `Version: 2.1.0` and keeps `Release: 1` from the spec.

## Build environment

The workflow builds inside:

```text
public.ecr.aws/amazonlinux/amazonlinux:2023
```

This makes Amazon Linux 2023 the reference build environment while keeping the resulting package architecture-independent (`noarch`).

## Source archive

The workflow creates:

```text
postfix-custom-mailserver-VERSION.tar.gz
```

with this top-level structure:

```text
postfix-custom-mailserver-VERSION/
├── SOURCES/
│   ├── add-alias.sh
│   ├── generate-dkim-key.sh
│   ├── mailserver-configure.sh
│   └── mailserver-validate.sh
├── LICENSE
└── README.md
```

The spec uses `%setup -q -n %{name}-%{version}`, so the source archive name and extracted directory must stay synchronized with the Git tag version.

## Local build

Install the RPM build tools:

```bash
sudo dnf install rpm-build rpmdevtools systemd-rpm-macros tar gzip
```

Initialize the RPM tree:

```bash
rpmdev-setuptree
```

For a local build, create the same source archive layout used by CI, copy it into `~/rpmbuild/SOURCES/`, copy the spec into `~/rpmbuild/SPECS/`, set the desired `Version:` in the spec, then run:

```bash
rpmbuild -ba ~/rpmbuild/SPECS/postfix-custom-mailserver.spec
```

## CI validation

Before building, CI checks:

- required repository files exist;
- all shell scripts pass `bash -n`;
- RPM spec parsing succeeds with `rpmspec --parse`;
- the spec version matches the Git tag;
- `Source0` matches the generated source archive;
- `%setup` matches the source archive top-level directory.

After building, CI verifies both the binary RPM and SRPM and uploads them as workflow artifacts and GitHub Release assets.
