# Build

Install RPM build tooling, then:

```bash
mkdir -p ~/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cp SPECS/postfix-custom-mailserver.spec ~/rpmbuild/SPECS/
cp SOURCES/* ~/rpmbuild/SOURCES/
rpmbuild -ba ~/rpmbuild/SPECS/postfix-custom-mailserver.spec
```

The resulting RPM will be under `~/rpmbuild/RPMS/noarch/`.

For a private package, build and test it separately on each supported OS release before deployment.
