#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

(
  # Source, list and package checks must never invoke installers or systemctl.
  apt-get() { printf 'mutation\n' >> "$tmp_root/mutations"; return 99; }
  systemctl() { printf 'mutation\n' >> "$tmp_root/mutations"; return 99; }
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/common.sh"
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/installers.sh"
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/package_db.sh"
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/removal.sh"
  OS_ID=altlinux OS_LIKE= OS_NAME=ALT OS_VARIANT_ID=kworkstation
  load_os_release() { :; }
  log() { :; }
  list_required_packages > "$tmp_root/alt.list"
  for pkg in krb5-kinit libsasl2-plugin-gssapi samba-dc-libs sssd-ldap sssd-krb5; do
    grep -Fxq "$pkg" "$tmp_root/alt.list"
  done
  ! grep -Fxq krb5-workstation "$tmp_root/alt.list"
  ! grep -Fxq libldb-modules-dc "$tmp_root/alt.list"
  is_removable_domain_package krb5-kinit
  is_removable_domain_package samba-dc-libs
  OS_ID=debian OS_LIKE=
  ! is_removable_domain_package krb5-kinit
  ! is_removable_domain_package samba-dc-libs
  for OS_ID in debian ubuntu astra; do
    OS_LIKE= OS_VARIANT_ID=
    list_required_packages > "$tmp_root/deb.list"
    diff -u <(printf '%s\n' "${DEB_REQUIRED_PACKAGES[@]}") "$tmp_root/deb.list"
  done
  have_cmd() { [[ "$1" == dnf ]]; }
  for OS_ID in redos rhel alteros; do
    OS_LIKE=rhel
    list_required_packages > "$tmp_root/rpm.list"
    diff -u <(printf '%s\n' "${RPM_REQUIRED_PACKAGES[@]}") "$tmp_root/rpm.list"
  done
  [[ ! -e "$tmp_root/mutations" ]]
)

(
  # The public launcher sources modules inside source_join_module().
  load_module() { . "$ROOT_DIR/linux/.join-to-domain/lib/dependencies.sh"; }
  load_module
  is_altlinux() { [[ "$OS_ID" == altlinux ]]; }
  OS_ID=altlinux PACKAGE_DB=rpm
  rpm() { printf '%s\n' "$*" >> "$tmp_root/rpm.queries"; [[ "$*" == '-q krb5-kinit' || "$*" == '-q samba-dc-libs' ]]; }
  is_package_installed krb5-workstation
  is_package_installed libldb-modules-dc
  OS_ID=redos
  ! is_package_installed krb5-workstation
  grep -Fxq -- '-q krb5-workstation' "$tmp_root/rpm.queries"
  for pkg in libsasl2-plugin-gssapi samba-dc-libs sssd-ldap sssd-krb5; do
    [[ -z "$(package_binaries "$pkg")" ]]
  done
  [[ "$(package_binaries krb5-kinit)" == $'kinit\nklist\nkvno' ]]

  # Package-only modules are checked in RPM and never treated as commands.
  load_required_packages() { PACKAGE_DEPENDENCIES=(krb5-kinit libsasl2-plugin-gssapi samba-dc-libs sssd-ldap sssd-krb5); }
  detect_package_manager() { return 0; }
  log() { :; }
  info() { :; }
  error() { :; }
  ui_text() { printf '%s' "$1"; }
  have_executable() { printf '%s\n' "$1" >> "$tmp_root/commands.checked"; [[ "$1" == kinit || "$1" == klist || "$1" == kvno ]]; }
  OS_ID=altlinux
  rpm() { [[ "$1" == -q ]]; }
  check_dependencies
  [[ "$(cat "$tmp_root/commands.checked")" == $'kinit\nklist\nkvno' ]]
  [[ "${#MISSING_PACKAGES[@]}" == 0 && "${#MISSING_BINARIES[@]}" == 0 ]]
)

(
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/common.sh"
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/package_db.sh"
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/local_packages.sh"
  OS_ID=altlinux OS_LIKE= WITH_SALT=1 PM=apt-get
  RPM_DIR="$tmp_root/rpms" LOG_FILE="$tmp_root/install.log"
  mkdir -p "$RPM_DIR"
  touch "$RPM_DIR/salt_minion.rpm" "$RPM_DIR/salt_common.rpm"
  runtime_text() { printf '%s' "$*"; }
  get_rpm_package_name() { case "$1" in *salt_minion*) echo salt-minion ;; *) echo salt ;; esac; }
  get_rpm_package_version() { echo 3007.9-0; }
  get_rpm_package_evr() { case "$1" in -q) echo 0:3008.3-alt1 ;; *) echo 0:3007.9-0 ;; esac; }
  rpm() { [[ "$1" == -q ]] && echo 3008.3-alt1; }
  rpmevrcmp() { [[ "$1" == 0:3008.3-alt1 && "$2" == 0:3007.9-0 ]]; echo 1; }
  salt_minion_binary_exists() { return 0; }
  salt_minion_unit_exists() { return 0; }
  salt-minion() { [[ "$1" == --version ]]; }
  salt-call() { printf '%s\n' "$*" >> "$tmp_root/salt.validation"; }
  track_local_package() { echo tracked >> "$tmp_root/tracked"; }
  apt-get() { echo install >> "$tmp_root/mutations"; return 99; }
  install_local_rpm_packages
  [[ ! -e "$tmp_root/tracked" && ! -e "$tmp_root/mutations" ]]
  grep -Fxq -- '--local --retcode-passthrough test.version' "$tmp_root/salt.validation"
  grep -Fxq -- '--local --retcode-passthrough sys.list_functions pkg' "$tmp_root/salt.validation"
  rpmevrcmp() { echo invalid; }
  ! compare_rpm_evr 0:3008.3-alt1 0:3007.9-0
  rpm() { printf '(none):3008.3-alt1'; }
  [[ "$(get_rpm_package_evr -q salt-minion)" == 0:3008.3-alt1 ]]
)

(
  # Native RPM vectors also run when this test is executed on ALT.
  . "$ROOT_DIR/linux/.join-to-domain/lib/install/package_db.sh"
  have_cmd() { command -v "$1" >/dev/null 2>&1; }
  if have_cmd rpmevrcmp; then
    [[ "$(compare_rpm_evr 0:3008.3-alt1 0:3007.9-0)" == 1 ]]
    [[ "$(compare_rpm_evr 1:3007.9-0 0:3008.3-alt1)" == 1 ]]
    [[ "$(compare_rpm_evr 0:3008.3-alt2 0:3008.3-alt1)" == 1 ]]
    [[ "$(compare_rpm_evr 0:3008.3-alt1 0:3008.3-alt1)" == 0 ]]
    [[ "$(compare_rpm_evr 0:3007.9-0 0:3008.3-alt1)" == -1 ]]
  fi
)
printf 'ALT packages and Salt protection tests: OK\n'
