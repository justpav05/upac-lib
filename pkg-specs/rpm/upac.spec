Name:           upac
Version:        %{version}
Release:        1%{?dist}
Summary:        A modular Linux package manager
License:        TBD
URL:            https://github.com/justpav05/upac

BuildArch:      x86_64

%description
Upac is a package manager for Linux-compatible systems. It manages the updating, removal, and installation of various package formats using different backends. It also supports OSTree for rolling back the state of binaries to specific commits.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib
mkdir -p %{buildroot}/etc/upac

cp %{_topdir}/root/usr/bin/upac         %{buildroot}/usr/bin/
cp %{_topdir}/root/usr/lib/libupac.so   %{buildroot}/usr/lib/
cp %{_topdir}/root/usr/lib/libupac-backend-arch.so \
                                         %{buildroot}/usr/lib/
cp %{_topdir}/root/usr/lib/libupac-backend-rpm.so \
                                         %{buildroot}/usr/lib/
cp %{_topdir}/root/etc/upac/config.toml.example \
                                         %{buildroot}/etc/upac/

%files
/usr/bin/upac
/usr/lib/libupac.so
/usr/lib/libupac-backend-arch.so
/usr/lib/libupac-backend-rpm.so
%config(noreplace) /etc/upac/config.toml.example

%post
ldconfig

%postun
ldconfig

%changelog
* %(date "+%a %b %d %Y") upac maintainer <aksenovpaveldmitrievich@gmail.com> - %{version}-1
- Initial package
