Name:           postfix-custom-mailserver
Version:        0.0.0
Release:        1%{?dist}
Summary:        Idempotent Postfix and OpenDKIM integration for application mail delivery
License:        MIT
URL:            https://github.com/DmytroMosnenko/postfix-custom-mailserver
BuildArch:      noarch
Source0:        postfix-custom-mailserver-%{version}.tar.gz

Requires:       postfix
Requires:       cyrus-sasl
Requires:       cyrus-sasl-plain
Requires:       opendkim
Requires:       opendkim-tools
Requires(post): systemd
Requires(postun): systemd

%description
Private production RPM for integrating Postfix and OpenDKIM on RPM-based servers.
The package installs idempotent administration helpers and applies only a managed
configuration block to existing Postfix/OpenDKIM configuration files. Existing
administrator configuration outside the managed blocks is preserved.

%prep
%setup -q -n %{name}-%{version}

%build

%install
rm -rf %{buildroot}

install -D -m 0755 SOURCES/mailserver-configure.sh \
    %{buildroot}%{_libexecdir}/%{name}/mailserver-configure.sh
install -D -m 0755 SOURCES/generate-dkim-key.sh \
    %{buildroot}%{_libexecdir}/%{name}/generate-dkim-key.sh
install -D -m 0755 SOURCES/add-alias.sh \
    %{buildroot}%{_libexecdir}/%{name}/add-alias.sh
install -D -m 0755 SOURCES/mailserver-validate.sh \
    %{buildroot}%{_libexecdir}/%{name}/mailserver-validate.sh

install -D -m 0644 README.md \
    %{buildroot}%{_docdir}/%{name}/README.md
install -D -m 0644 LICENSE \
    %{buildroot}%{_licensedir}/%{name}/LICENSE

%pre
# Postfix and OpenDKIM own their service accounts. Do not create or modify them.
exit 0

%post
# The configuration helper is deliberately idempotent. It only replaces the
# package-owned blocks and preserves administrator configuration elsewhere.
if [ -x %{_libexecdir}/%{name}/mailserver-configure.sh ]; then
    %{_libexecdir}/%{name}/mailserver-configure.sh --apply || {
        echo "WARNING: %{name} configuration was not fully applied." >&2
        echo "Run: %{_libexecdir}/%{name}/mailserver-configure.sh --apply" >&2
    }
fi

# Enable the existing services but do not start services that were stopped.
# The configuration helper reloads/restarts only services that were already active.
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable postfix.service >/dev/null 2>&1 || :
systemctl enable opendkim.service >/dev/null 2>&1 || :

exit 0

%preun
# On package removal, deliberately leave Postfix/OpenDKIM services and all
# administrator configuration untouched.
exit 0

%postun
systemctl daemon-reload >/dev/null 2>&1 || :
exit 0

%files
%license %{_licensedir}/%{name}/LICENSE
%doc %{_docdir}/%{name}/README.md
%{_libexecdir}/%{name}/mailserver-configure.sh
%{_libexecdir}/%{name}/generate-dkim-key.sh
%{_libexecdir}/%{name}/add-alias.sh
%{_libexecdir}/%{name}/mailserver-validate.sh

%changelog
* Thu Aug 20 2026 Package Maintainer <amidtrader@gmail.com> - 0.0.0-1
- Reworked package for idempotent install and upgrade behavior.
- Preserve administrator Postfix/OpenDKIM configuration outside managed blocks.
- Explicitly configure the OpenDKIM TCP socket used by Postfix.
- Do not overwrite TrustedHosts or service configuration on package removal.
- Add validation and safer DKIM key/alias administration helpers.
