Name:           postfix-custom-mailserver
Version:        3.0
Release:        1%{?dist}
Summary:        Idempotent Postfix + OpenDKIM setup for outbound application mail
License:        MIT
URL:            https://github.com/DmytroMosnenko/postfix-custom-mailserver
BuildArch:      noarch
Source0:        postfix-custom-mailserver-%{version}.tar.gz

# Runtime dependencies — these packages own the users/groups and base configs
Requires:       postfix
Requires:       cyrus-sasl
Requires:       cyrus-sasl-plain
Requires:       opendkim
Requires:       opendkim-tools

# systemd macros for %post/%preun/%postun
Requires(post):   systemd
Requires(preun):  systemd
Requires(postun): systemd

%description
Private production RPM for configuring Postfix as an outbound-only SMTP relay
for application mail (Python scripts, cron, etc.) on Amazon Linux 2023 and
AlmaLinux, with OpenDKIM signing to satisfy Gmail/Outlook deliverability.

The package installs idempotent administration helpers:
  mailserver-configure.sh   — apply/refresh Postfix + OpenDKIM configuration
  generate-dkim-key.sh      — generate DKIM keys and register them
  add-alias.sh              — safely add /etc/aliases entries
  mailserver-validate.sh    — verify the full setup
  mailserver-preinstall-check.sh — diagnose existing state before install

Configuration strategy:
  - Postfix main.cf: only a clearly-marked managed block is touched.
    Existing administrator settings outside the block are preserved.
  - OpenDKIM: individual settings are patched in place; TrustedHosts/KeyTable/
    SigningTable are created if absent, never overwritten if they exist.
  - DKIM keys are never touched by this package after creation.
  - Original configs are backed up once (*.pcm-orig) before first modification.
  - Safe to install over an existing messy installation.

%prep
%setup -q

%build
# Nothing to compile.

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
install -D -m 0755 SOURCES/mailserver-preinstall-check.sh \
    %{buildroot}%{_libexecdir}/%{name}/mailserver-preinstall-check.sh

install -D -m 0644 README.md \
    %{buildroot}%{_docdir}/%{name}/README.md

%pre
# The required postfix and opendkim packages own their service accounts.
# We do not create users or groups here.
exit 0

%post
# Apply configuration after install or upgrade.
# The script is idempotent — safe to run on a server with an existing
# (possibly messy) postfix/opendkim setup.
if [ -x %{_libexecdir}/%{name}/mailserver-configure.sh ]; then
    %{_libexecdir}/%{name}/mailserver-configure.sh --apply || {
        echo "WARNING: %{name}: configuration apply had errors." >&2
        echo "  Run manually: %{_libexecdir}/%{name}/mailserver-configure.sh --apply" >&2
        echo "  Then check:   %{_libexecdir}/%{name}/mailserver-validate.sh" >&2
    }
fi

# Enable services at boot but do NOT start services that were stopped.
# A running service gets reloaded by the configure script above.
# ($1 == 1: fresh install; $1 == 2: upgrade)
if [ "$1" -ge 1 ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    systemctl enable postfix.service  >/dev/null 2>&1 || :
    systemctl enable opendkim.service >/dev/null 2>&1 || :
fi

# Print usage summary
cat << 'POSTINSTALL'

========================================================================
 postfix-custom-mailserver installed
========================================================================
 Helpers are in: %{_libexecdir}/%{name}/

 NEXT STEPS:
   1. Generate DKIM key for your domain:
        %{_libexecdir}/%{name}/generate-dkim-key.sh yourdomain.com

   2. Add the printed DNS TXT record to your domain registrar.

   3. Add email aliases (e.g. forward root mail externally):
        %{_libexecdir}/%{name}/add-alias.sh root you@gmail.com

   4. Run the validator to confirm everything is working:
        %{_libexecdir}/%{name}/mailserver-validate.sh

   5. Test outbound mail:
        echo "Test from $(hostname)" | mail -s "Test" you@gmail.com

 NOTE: inet_interfaces = loopback-only (only localhost can relay).
 Postfix does NOT listen on external interfaces. This is intentional.
========================================================================

POSTINSTALL

exit 0

%preun
# $1 == 0: final removal. $1 == 1: upgrade (do nothing here).
# We do NOT disable/stop postfix or opendkim on removal — they are
# infrastructure services the admin controls independently.
# We do NOT remove main.cf, opendkim.conf, or DKIM keys — admin data.
if [ "$1" -eq 0 ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
fi
exit 0

%postun
# $1 == 0: final removal — nothing to restart.
# $1 >= 1: upgrade — services were already reloaded by %post configure script.
systemctl daemon-reload >/dev/null 2>&1 || :
exit 0

%files
%{_libexecdir}/%{name}/mailserver-configure.sh
%{_libexecdir}/%{name}/generate-dkim-key.sh
%{_libexecdir}/%{name}/add-alias.sh
%{_libexecdir}/%{name}/mailserver-validate.sh
%{_libexecdir}/%{name}/mailserver-preinstall-check.sh
%doc %{_docdir}/%{name}/README.md

%changelog
* Fri Aug 21 2026 Dmytro Mosnenko <admin@example.com> - 3.1-1
- Fixed: comment_out_upstream_params() silences "overriding earlier entry" warnings
  from stock postfix main.cf by commenting out conflicting upstream defaults outside
  the managed block rather than just appending over them.
- Fixed: removed unnecessary postfix check call from generate-dkim-key.sh that was
  spamming the same warnings on every key generation.
- Fixed: preinstall-check.sh integer expression error in append_count test.
- Fixed: %systemd_post/preun/postun replaced with inline shell (macro fails in AL2023).

* Fri Aug 21 2026 Dmytro Mosnenko <admin@example.com> - 3.0-1
- Complete rewrite; replaces Gemini v1 and ChatGPT v2 versions.
- Fixed: replace_managed_block was broken on first-install (block absent) path.
- Fixed: ensure_opendkim_setting substring match bug (Mode matching ModeSpec etc).
- Fixed: inet_interfaces = all replaced with loopback-only (security).
- Fixed: smtpd_relay_restrictions added to prevent open relay.
- Fixed: ensure_line was defined inside else-block (bash scoping footgun).
- Added: mailserver-preinstall-check.sh for diagnosing existing messy installs.
- Added: myhostname/mydomain guidance in README.
- Added: Proper color-coded validation output.
- Improved: Atomic file replacement (tmp + cat) preserving inodes/permissions.
- Improved: All scripts have input validation and clear error messages.
