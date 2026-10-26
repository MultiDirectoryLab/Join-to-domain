#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

for dig_available in 0 1; do
  (
    # Probe only command availability; do not depend on this machine's dig.
    command() {
      if [[ "$*" == '-v dig' ]]; then
        [[ "$dig_available" == 1 ]]
      else
        builtin command "$@"
      fi
    }
    apt-get() { touch "$TMP_ROOT/package-manager-called"; return 99; }
    dnf() { touch "$TMP_ROOT/package-manager-called"; return 99; }
    yum() { touch "$TMP_ROOT/package-manager-called"; return 99; }
    # shellcheck source=/dev/null
    . "$ROOT_DIR/linux/.join-to-domain/lib/install/common.sh"
    # Sourcing common settings must not select or install DNS packages.
    for array_name in DEB_REQUIRED_PACKAGES RPM_REQUIRED_PACKAGES RPM_APT_REQUIRED_PACKAGES ALT_REQUIRED_PACKAGES; do
      declare -n packages="$array_name"
      [[ " ${packages[*]} " != *' dnsutils '* && " ${packages[*]} " != *' bind-utils '* ]]
    done
    # shellcheck source=/dev/null
    . "$ROOT_DIR/linux/.join-to-domain/lib/install/installers.sh"
    prepare_dns_probe_packages
    prepare_dns_probe_packages
    for array_name in DEB_REQUIRED_PACKAGES RPM_REQUIRED_PACKAGES RPM_APT_REQUIRED_PACKAGES ALT_REQUIRED_PACKAGES; do
      declare -n packages="$array_name"
      if [[ "$dig_available" == 1 ]]; then
        [[ " ${packages[*]} " != *' dnsutils '* && " ${packages[*]} " != *' bind-utils '* ]]
      elif [[ "$array_name" == DEB_REQUIRED_PACKAGES ]]; then
        [[ " ${packages[*]} " == *' dnsutils '* ]]
        [[ "$(printf '%s\n' "${packages[@]}" | grep -c '^dnsutils$')" == 1 ]]
      else
        [[ " ${packages[*]} " == *' bind-utils '* ]]
        [[ "$(printf '%s\n' "${packages[@]}" | grep -c '^bind-utils$')" == 1 ]]
      fi
    done
    [[ ! -e "$TMP_ROOT/package-manager-called" ]]
  )
done
# Exercise the actual Join preflight with a missing dig. No transaction,
# discovery or package installation may begin as a side effect of Join.
set +e
(
  set -Eeuo pipefail
  for module in common leave flow; do
    # shellcheck source=/dev/null
    . "$ROOT_DIR/linux/.join-to-domain/lib/configure/$module.sh"
  done
  need_root() { :; }
  setup_logging() { :; }
  load_os_release() { :; }
  check_system_capabilities() { :; }
  command() {
    if [[ "$1" == -v ]]; then [[ "$2" != dig ]]; else builtin command "$@"; fi
  }
  die() { printf '%s\n' "$*" > "$TMP_ROOT/preflight-error"; exit 17; }
  create_join_backup() { touch "$TMP_ROOT/unexpected-backup"; exit 90; }
  prepare_service_info() { touch "$TMP_ROOT/unexpected-discovery"; exit 91; }
  apt-get() { touch "$TMP_ROOT/package-manager-called"; exit 92; }
  dnf() { touch "$TMP_ROOT/package-manager-called"; exit 92; }
  yum() { touch "$TMP_ROOT/package-manager-called"; exit 92; }
  join_domain
)
status=$?
set -e
[[ "$status" == 17 ]]
grep -Fxq 'Command not found: dig' "$TMP_ROOT/preflight-error"
[[ ! -e "$TMP_ROOT/unexpected-backup" && ! -e "$TMP_ROOT/unexpected-discovery" && ! -e "$TMP_ROOT/package-manager-called" ]]
printf 'DNS probe package dependency tests passed\n'
