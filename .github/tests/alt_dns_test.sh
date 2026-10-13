#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../linux/.join-to-domain" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

. "$ROOT_DIR/lib/configure/common.sh"
. "$ROOT_DIR/lib/configure/state.sh"
. "$ROOT_DIR/lib/configure/identity_dns.sh"
. "$ROOT_DIR/lib/configure/leave.sh"

log() { :; }
warn() { printf 'warning: %s\n' "$*" >&2; }
is_redos_or_rhel_like() { return 1; }
restore_authselect_state() { :; }
restore_networkmanager_dns_state() { :; }
restore_sssd_socket_state() { :; }
refresh_md_trust_store() { :; }
detect_default_iface() { printf '%s\n' "${TEST_IFACE:-ens33}"; }
configure_dns_networkmanager() { printf 'unexpected NetworkManager call\n' >&2; return 99; }
configure_dns_static_resolv_conf() { printf 'unexpected static resolver call\n' >&2; return 99; }
configure_dns_systemd_resolved() { printf 'unexpected resolved call\n' >&2; return 99; }
have_cmd() { [[ "$1" == resolvconf ]]; }

MD_STATE_DIR="$TMP_ROOT/state"
MD_BACKUPS_ROOT="$TMP_ROOT/backups"
MD_PENDING_BACKUP="$MD_STATE_DIR/active-backup"
MD_ORIGINAL_BACKUP="$MD_STATE_DIR/original-backup"
MD_TRANSACTION_STATE="$MD_STATE_DIR/transaction.env"
MD_JOIN_ENV="$MD_STATE_DIR/join.env"
MD_ALT_IFACES_DIR="$TMP_ROOT/etc/net/ifaces"
MD_NM_DNS_STATE="$MD_STATE_DIR/networkmanager-dns.env"
LOG_FILE="$TMP_ROOT/log"
OS_ID=altlinux
OS_LIKE=
mkdir -p "$MD_ALT_IFACES_DIR/ens33" "$TMP_ROOT/runtime"
printf 'original-host\n' > "$TMP_ROOT/hostname"
hostname() {
  if [[ $# == 0 ]]; then cat "$TMP_ROOT/hostname";
  else printf '%s\n' "$1" > "$TMP_ROOT/hostname"; fi
}

resolvconf() {
  printf '%s\n' "$*" >> "$TMP_ROOT/calls"
  case "$1" in
    -i)
      local path
      for path in "$TMP_ROOT/runtime/"*; do
        [[ -f "$path" ]] || continue
        printf '%s\n' "${path##*/}"
      done
      ;;
    -l)
      [[ -f "$TMP_ROOT/runtime/$2" ]] || return 2
      printf '# resolv.conf from %s\n' "$2"
      sed '/^$/d' "$TMP_ROOT/runtime/$2"
      ;;
    -x)
      [[ "$2" == -a && "${FAIL_ADD:-0}" == 0 ]] || return 1
      cat > "$TMP_ROOT/runtime/$3"
      ;;
    -f)
      [[ "$2" == -d && "${FAIL_DELETE:-0}" == 0 ]] || return 1
      rm -f -- "$TMP_ROOT/runtime/$3"
      ;;
    -u) [[ "${FAIL_UPDATE:-0}" == 0 ]] ;;
    *) return 1 ;;
  esac
}
managed_join_paths() { printf '%s\n' "$MD_ALT_IFACES_DIR/ens33/resolv.conf"; }

# Existing file, modes and unrelated runtime sources survive Join + Leave.
printf 'search original.example\nnameserver 1.1.1.1\noptions timeout:2\n' > "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
chmod 0640 "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
cp -a "$MD_ALT_IFACES_DIR/ens33/resolv.conf" "$TMP_ROOT/original"
printf 'nameserver 9.9.9.9\n' > "$TMP_ROOT/runtime/ens33.dhcp"
create_join_backup
first_backup="$MD_BACKUP_DIR"
md_set_resolv_first '192.168.69.222'
grep -Fxq 'search original.example' "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
grep -Fxq 'nameserver 1.1.1.1' "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
[[ "$(head -n1 "$MD_ALT_IFACES_DIR/ens33/resolv.conf")" == 'nameserver 192.168.69.222' ]]
md_set_resolv_first '192.168.69.222'
[[ "$(grep -c '^-x -a ens33.multidirectory$' "$TMP_ROOT/calls")" == 1 ]]
validate_join_backup

# Failed Rejoin restores the joined DNS instead of the original pre-Join DNS.
create_recovery_backup
md_set_resolv_first '192.168.69.223'
MD_RESTORE_OPERATION_ONLY=1
restore_backups
grep -Fxq 'nameserver 192.168.69.222' "$TMP_ROOT/runtime/ens33.multidirectory"
! grep -q '192.168.69.223' "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
MD_RESTORE_OPERATION_ONLY=0
MD_BACKUP_DIR="$first_backup"
MD_MANIFEST="$first_backup/manifest.env"
restore_backups
cmp "$TMP_ROOT/original" "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
[[ "$(stat -c '%a:%u:%g' "$TMP_ROOT/original")" == "$(stat -c '%a:%u:%g' "$MD_ALT_IFACES_DIR/ens33/resolv.conf")" ]]
[[ ! -f "$TMP_ROOT/runtime/ens33.multidirectory" ]]
grep -Fxq 'nameserver 9.9.9.9' "$TMP_ROOT/runtime/ens33.dhcp"

# Original absence is preserved, and backend failure does not fall through.
rm -f "$MD_ALT_IFACES_DIR/ens33/resolv.conf"
create_join_backup
FAIL_ADD=1
if md_set_resolv_first '192.168.69.222'; then exit 1; fi
FAIL_ADD=0
restore_backups
[[ ! -e "$MD_ALT_IFACES_DIR/ens33/resolv.conf" ]]
md_set_resolv_first '192.168.69.222'
FAIL_DELETE=1
if restore_backups; then exit 1; fi
[[ -f "$MD_BACKUP_DIR/alt-dns/ens33/runtime.existed" && -f "$MD_MANIFEST" ]]
FAIL_DELETE=0
FAIL_UPDATE=1
if restore_backups; then exit 1; fi
[[ -f "$MD_BACKUP_DIR/alt-dns/ens33/runtime.existed" ]]
FAIL_UPDATE=0
restore_backups
[[ ! -e "$MD_ALT_IFACES_DIR/ens33/resolv.conf" ]]

# Unsafe names and absent interface directories are rejected before mutation.
TEST_IFACE=../escape
if md_set_resolv_first '192.168.69.222'; then exit 1; fi
TEST_IFACE=missing0
if md_set_resolv_first '192.168.69.222'; then exit 1; fi
unset TEST_IFACE

# Read-only NM-controlled etcnet interfaces restore their runtime source at boot.
MD_ALT_DNS_UNIT_DIR="$TMP_ROOT/units"
mkdir -p "$MD_ALT_DNS_UNIT_DIR"
printf 'DISABLED="yes"\nNM_CONTROLLED=yes\n' > "$MD_ALT_IFACES_DIR/ens33/options"
have_cmd() { [[ "$1" == resolvconf || "$1" == systemctl ]]; }
find_executable() { printf '/usr/sbin/resolvconf\n'; }
systemctl() {
  printf '%s\n' "$*" >> "$TMP_ROOT/unit-calls"
  case "$1" in
    is-enabled) printf 'not-found\n'; return 1 ;;
    is-active) printf 'inactive\n'; return 3 ;;
    *) return 0 ;;
  esac
}
create_join_backup
md_set_resolv_first '192.168.69.222'
grep -Fxq "StandardInput=file:$MD_ALT_IFACES_DIR/ens33/resolv.conf" "$MD_ALT_DNS_UNIT_DIR/multidirectory-dns-ens33.service"
grep -Fxq 'ExecStart=/usr/sbin/resolvconf -x -a ens33.multidirectory' "$MD_ALT_DNS_UNIT_DIR/multidirectory-dns-ens33.service"
grep -Fxq -- '--quiet enable multidirectory-dns-ens33.service' "$TMP_ROOT/unit-calls"
restore_backups
[[ ! -e "$MD_ALT_DNS_UNIT_DIR/multidirectory-dns-ens33.service" ]]
grep -Fxq -- '--quiet disable multidirectory-dns-ens33.service' "$TMP_ROOT/unit-calls"
[[ ! -e "$MD_ALT_IFACES_DIR/ens33/resolv.conf" ]]
restore_backups # Retry after successful file restoration is safe.

# ALT rollback must reset NM's cached global hostname as well as kernel state.
# NM regenerates its resolver search domain from that cache, not /etc/hostname.
create_join_backup
printf 'original-host\n' > "$TMP_ROOT/hostname"
printf 'original-host.example\n' > "$TMP_ROOT/nm-hostname"
nmcli() {
  if [[ "$*" == '-t -f RUNNING general' ]]; then printf 'running\n'; return 0; fi
  [[ "$1" == general && "$2" == hostname ]] || return 99
  if [[ $# == 2 ]]; then cat "$TMP_ROOT/nm-hostname"; return 0; fi
  [[ "${FAIL_NM_HOSTNAME:-0}" == 0 ]] || return 1
  printf '%s\n' "$3" > "$TMP_ROOT/nm-hostname"
  # Simulate NetworkManager regenerating its own DNS source from the hostname.
  printf 'nameserver 9.9.9.9\n' > "$TMP_ROOT/runtime/NetworkManager"
  if [[ "$3" == *.md.loc ]]; then printf 'search md.loc\n' >> "$TMP_ROOT/runtime/NetworkManager"; fi
}
have_cmd() { [[ "$1" == nmcli || "$1" == resolvconf ]]; }
backup_alt_hostname_state
hostname original-host.md.loc
nmcli general hostname original-host.md.loc
backup_alt_hostname_state # The first snapshot remains immutable.
FAIL_NM_HOSTNAME=1
if restore_alt_hostname_state; then exit 1; fi
[[ -f "$MD_BACKUP_DIR/alt-hostname.env" ]]
FAIL_NM_HOSTNAME=0
restore_alt_hostname_state
[[ "$(hostname)" == original-host ]]
[[ "$(nmcli general hostname)" == original-host.example ]]
! grep -q 'search md.loc' "$TMP_ROOT/runtime/NetworkManager"
[[ "$(stat -c '%a' "$MD_BACKUP_DIR/alt-hostname.env")" == 600 ]]

# Existing generic backend order remains unchanged on every other OS.
configure_dns_networkmanager() { printf 'nm\n' >> "$TMP_ROOT/generic"; return 0; }
for OS_ID in astra debian ubuntu alteros redos rhel; do
  md_set_resolv_first '192.168.69.222'
done
[[ "$(wc -l < "$TMP_ROOT/generic")" == 6 ]]
printf 'ALT DNS Join/Leave/Rejoin, idempotence, failure recovery and generic backend tests: OK\n'
