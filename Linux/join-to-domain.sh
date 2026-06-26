#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PACKAGES_SCRIPT="${SCRIPT_DIR}/install_packages.sh"
CONFIGURE_SCRIPT="${SCRIPT_DIR}/configure.sh"
LOG_FILE="/var/log/join-to-domain.log"
REJOIN_LOG_FILE="/var/log/multidirectory-rejoin.log"
MD_CLEANUP_LOG_FILE="/var/log/multidirectory-join.log"
MD_ETC_DIR="/etc/MultiDirectory"
MD_STATE_DIR="${MD_ETC_DIR}/state"
MD_BACKUP_DIR="${MD_STATE_DIR}/backups"
MD_MANIFEST="${MD_STATE_DIR}/manifest"
MD_JOIN_ENV="/etc/MultiDirectory/state/join.env"
SALT_PKG_MODULE_DST="/var/cache/salt/minion/extmods/modules/pkg.py"
DEBUG=0
DRY_RUN=0
LOG_ENABLED=0
PACKAGE_MANAGER=""
PACKAGE_DB=""
INSTALL_PROFILE=""
OS_ID=""
OS_LIKE=""
OS_NAME=""
REQUIRED_PACKAGES=()
MISSING_PACKAGES=()
MISSING_BINARIES=()
DETECTED_DOMAIN_STATE=""
DETECTED_DOMAIN_REASONS=()

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
  local level="$1"
  shift

  if [[ "$LOG_ENABLED" -eq 1 ]]; then
    printf '[%s] %s\n' "$level" "$*" >> "$LOG_FILE" || true
  fi
}

rejoin_log() {
  if touch "$REJOIN_LOG_FILE" 2>/dev/null; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$REJOIN_LOG_FILE" || true
  fi

  log "REJOIN" "$*"
}

cleanup_log() {
  if touch "$MD_CLEANUP_LOG_FILE" 2>/dev/null; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$MD_CLEANUP_LOG_FILE" || true
  fi

  log "CLEANUP" "$*"
}

info() {
  printf '%b\n' "${GREEN}[OK]${NC} $*"
  log "OK" "$*"
}

warn() {
  printf '%b\n' "${YELLOW}[WARN]${NC} $*"
  log "WARN" "$*"
}

error() {
  printf '%b\n' "${RED}[ERROR]${NC} $*" >&2
  log "ERROR" "$*"
}

debug() {
  if [[ "$DEBUG" -eq 1 ]]; then
    printf '[DEBUG] %s\n' "$*"
  fi

  log "DEBUG" "$*"
}

setup_logging() {
  local log_dir

  log_dir="$(dirname "$LOG_FILE")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    debug "Dry-run mode: logging to ${LOG_FILE} if writable"
  fi

  mkdir -p "$log_dir" 2>/dev/null || true
  if touch "$LOG_FILE" 2>/dev/null; then
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    LOG_ENABLED=1
  else
    LOG_ENABLED=0
    [[ "$DEBUG" -eq 1 ]] && printf '[DEBUG] Log file is not writable: %s\n' "$LOG_FILE"
  fi

  log "INFO" "Started join-to-domain.sh"
}

usage() {
  cat <<EOF
Usage: $0 [--debug] [--dry-run] [--help]

Options:
  --debug    Show verbose diagnostic output
  --dry-run  Print actions without changing the system
  --help     Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug)
        DEBUG=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        usage
        exit 2
        ;;
    esac

    shift
  done
}

pause() {
  local _

  printf '\nPress Enter to return to the main menu... '
  IFS= read -r _ || true
}

need_root_for_install() {
  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Package installation requires root. Run: sudo $0"
    return 1
  fi

  return 0
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

load_os_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-${OS_ID:-unknown}}"
}

is_deb_based() {
  [[ "${OS_ID}" =~ ^(debian|ubuntu|astra)$ ]] || [[ "${OS_LIKE}" =~ debian ]]
}

is_rpm_based() {
  [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|redos|altlinux)$ ]] || [[ "${OS_LIKE}" =~ (rhel|fedora|sisyphus|altlinux) ]]
}

is_altlinux() {
  [[ "${OS_ID}" == "altlinux" ]] || [[ "${OS_LIKE}" =~ (altlinux|sisyphus) ]]
}

detect_package_manager() {
  load_os_release

  if is_altlinux && have_cmd apt-get; then
    PACKAGE_MANAGER="apt-get"
    PACKAGE_DB="rpm"
    INSTALL_PROFILE="rpm-apt"
  elif have_cmd dnf; then
    PACKAGE_MANAGER="dnf"
    PACKAGE_DB="rpm"
    INSTALL_PROFILE="rpm"
  elif have_cmd yum; then
    PACKAGE_MANAGER="yum"
    PACKAGE_DB="rpm"
    INSTALL_PROFILE="rpm"
  elif have_cmd apt-get; then
    PACKAGE_MANAGER="apt"
    PACKAGE_DB="deb"
    INSTALL_PROFILE="deb"
  else
    PACKAGE_MANAGER=""
    PACKAGE_DB=""
    INSTALL_PROFILE=""
    error "No supported package manager found: apt-get, dnf or yum"
    return 1
  fi

  debug "Detected OS: ${OS_NAME}"
  debug "Detected package manager: ${PACKAGE_MANAGER}"
  debug "Detected package database: ${PACKAGE_DB}"
  return 0
}

load_required_packages() {
  REQUIRED_PACKAGES=()

  if ! need_script "$INSTALL_PACKAGES_SCRIPT"; then
    return 1
  fi

  mapfile -t REQUIRED_PACKAGES < <(bash "$INSTALL_PACKAGES_SCRIPT" list-required-packages)

  if [[ "${#REQUIRED_PACKAGES[@]}" -eq 0 ]]; then
    error "Installer returned an empty dependency list"
    return 1
  fi

  debug "Required packages: ${REQUIRED_PACKAGES[*]}"
  return 0
}

need_script() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    error "Required script not found: ${path}"
    return 1
  fi

  return 0
}

package_binaries() {
  case "$1" in
    ca-certificates|libnss-sss|libpam-sss|libpam-modules|sssd-client|oddjob-mkhomedir)
      ;;
    ldap-utils|openldap-clients)
      printf '%s\n' ldapwhoami
      ;;
    curl)
      printf '%s\n' curl
      ;;
    jq)
      printf '%s\n' jq
      ;;
    file)
      printf '%s\n' file
      ;;
    sudo)
      printf '%s\n' sudo
      ;;
    krb5-user|krb5-workstation)
      printf '%s\n' kinit klist
      ;;
    sssd)
      printf '%s\n' sssd
      ;;
    sssd-tools)
      printf '%s\n' sssctl
      ;;
    oddjob)
      printf '%s\n' oddjobd
      ;;
    openssh-server)
      printf '%s\n' sshd
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

is_package_installed() {
  local package="$1"

  case "$PACKAGE_DB" in
    deb)
      dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
      ;;
    rpm)
      rpm -q "$package" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

verify_package_installation() {
  local package="$1"

  if is_package_installed "$package"; then
    info "Installed: ${package}"
    return 0
  fi

  error "Package is not installed after installation attempt: ${package}"
  return 1
}

install_packages() {
  local packages=()
  local package failed=0

  if [[ "$#" -gt 0 ]]; then
    packages=("$@")
  fi

  log "INFO" "Install packages requested"

  if [[ -f "$INSTALL_PACKAGES_SCRIPT" ]]; then
    if ! need_root_for_install; then
      return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "Dry-run: JOIN_TO_DOMAIN_SKIP_CONFIGURE_PROMPT=1 bash ${INSTALL_PACKAGES_SCRIPT} join"
      return 0
    fi

    info "Running package installer: ${INSTALL_PACKAGES_SCRIPT}"
    JOIN_TO_DOMAIN_SKIP_CONFIGURE_PROMPT=1 bash "$INSTALL_PACKAGES_SCRIPT" join
    return $?
  fi

  if ! detect_package_manager; then
    return 1
  fi

  load_required_packages || return 1

  if [[ "$#" -eq 0 ]]; then
    packages=("${REQUIRED_PACKAGES[@]}")
  fi

  if ! need_root_for_install; then
    return 1
  fi

  if [[ "${#packages[@]}" -eq 0 ]]; then
    info "No packages to install"
    return 0
  fi

  case "$PACKAGE_MANAGER" in
    apt|apt-get)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: apt-get update"
        info "Dry-run: apt-get install -y ${packages[*]}"
      else
        info "Updating package index"
        if ! apt-get update; then
          error "apt-get update failed"
          return 1
        fi

        info "Installing required packages"
        if ! apt-get install -y "${packages[@]}"; then
          error "apt-get install failed"
          return 1
        fi
      fi
      ;;
    dnf|yum)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: ${PACKAGE_MANAGER} install -y ${packages[*]}"
      else
        info "Installing required packages"
        if ! "$PACKAGE_MANAGER" install -y "${packages[@]}"; then
          error "${PACKAGE_MANAGER} install failed"
          return 1
        fi
      fi
      ;;
  esac

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "Dry-run mode: package verification skipped"
    return 0
  fi

  for package in "${packages[@]}"; do
    verify_package_installation "$package" || failed=1
  done

  if [[ "$failed" -ne 0 ]]; then
    error "One or more packages failed verification"
    return 1
  fi

  info "Package installation completed"
  return 0
}

check_dependencies() {
  local package binary package_missing missing_binary_count

  MISSING_PACKAGES=()
  MISSING_BINARIES=()

  log "INFO" "Dependency check started"

  if ! detect_package_manager; then
    error "Missing required dependencies"
    return 1
  fi

  load_required_packages || return 1

  for package in "${REQUIRED_PACKAGES[@]}"; do
    package_missing=0

    if ! is_package_installed "$package"; then
      package_missing=1
    fi

    missing_binary_count=0
    while IFS= read -r binary; do
      [[ -n "$binary" ]] || continue

      if ! have_cmd "$binary"; then
        MISSING_BINARIES+=("${package}: ${binary}")
        missing_binary_count=$((missing_binary_count + 1))
      fi
    done < <(package_binaries "$package")

    if [[ "$package_missing" -eq 1 || "$missing_binary_count" -gt 0 ]]; then
      MISSING_PACKAGES+=("$package")
    fi
  done

  if [[ "${#MISSING_PACKAGES[@]}" -eq 0 && "${#MISSING_BINARIES[@]}" -eq 0 ]]; then
    info "All required dependencies are installed"
    return 0
  fi

  error "Missing required dependencies"
  printf '\nMissing packages:\n'
  for package in "${MISSING_PACKAGES[@]}"; do
    printf '  - %s\n' "$package"
  done

  if [[ "${#MISSING_BINARIES[@]}" -gt 0 ]]; then
    printf '\nMissing binaries:\n'
    for binary in "${MISSING_BINARIES[@]}"; do
      printf '  - %s\n' "$binary"
    done
  fi

  log "ERROR" "Missing packages: ${MISSING_PACKAGES[*]}"
  log "ERROR" "Missing binaries: ${MISSING_BINARIES[*]}"
  return 1
}

configure_domain() {
  log "INFO" "Domain configuration requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Domain configuration requires root. Run: sudo $0"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: MD_CALLED_FROM_INSTALL_PACKAGES=1 bash ${CONFIGURE_SCRIPT} join"
    return 0
  fi

  info "Running domain configuration: ${CONFIGURE_SCRIPT}"
  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" join

  return $?
}

add_domain_state_reason() {
  DETECTED_DOMAIN_REASONS+=("$1")
}

directory_has_entries() {
  local dir="$1"

  [[ -d "$dir" ]] || return 1
  find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

krb5_conf_looks_domain_managed() {
  [[ -f /etc/krb5.conf ]] || return 1

  if [[ -f "$MD_MANIFEST" ]] && grep -Fxq /etc/krb5.conf "$MD_MANIFEST" 2>/dev/null; then
    return 0
  fi

  grep -Eq '^[[:space:]]*dns_lookup_realm[[:space:]]*=[[:space:]]*false' /etc/krb5.conf 2>/dev/null &&
    grep -Eq '^[[:space:]]*ticket_lifetime[[:space:]]*=[[:space:]]*7d' /etc/krb5.conf 2>/dev/null &&
    grep -Eq '^[[:space:]]*renew_lifetime[[:space:]]*=[[:space:]]*14d' /etc/krb5.conf 2>/dev/null &&
    grep -Eq '^[[:space:]]*admin_server[[:space:]]*=' /etc/krb5.conf 2>/dev/null
}

detect_domain_config_state() {
  DETECTED_DOMAIN_STATE="clean"
  DETECTED_DOMAIN_REASONS=()

  [[ -f "$MD_JOIN_ENV" ]] && add_domain_state_reason "MultiDirectory join state found: ${MD_JOIN_ENV}"
  [[ -f "$MD_MANIFEST" ]] && add_domain_state_reason "MultiDirectory manifest found: ${MD_MANIFEST}"
  [[ -f "${MD_STATE_DIR}/rollback-in-progress" ]] && add_domain_state_reason "MultiDirectory rollback marker found: ${MD_STATE_DIR}/rollback-in-progress"

  if have_cmd realm && realm list 2>/dev/null | grep -q '^[^[:space:]]'; then
    add_domain_state_reason "realm reports configured domain membership"
  fi

  [[ -f /etc/sssd/sssd.conf ]] && add_domain_state_reason "SSSD configuration found: /etc/sssd/sssd.conf"
  directory_has_entries /etc/sssd/conf.d && add_domain_state_reason "SSSD snippets found: /etc/sssd/conf.d"
  [[ -f /etc/krb5.keytab ]] && add_domain_state_reason "Kerberos keytab found: /etc/krb5.keytab"
  krb5_conf_looks_domain_managed && add_domain_state_reason "Kerberos configuration found: /etc/krb5.conf"
  [[ -f /etc/sudoers.d/domain-admins ]] && add_domain_state_reason "Domain sudoers file found: /etc/sudoers.d/domain-admins"
  [[ -f /etc/ssh/sshd_config.d/ssh_md.conf ]] && add_domain_state_reason "Domain SSH configuration found: /etc/ssh/sshd_config.d/ssh_md.conf"
  [[ -f /etc/systemd/resolved.conf.d/MultiDirectory.conf ]] && add_domain_state_reason "MultiDirectory DNS configuration found: /etc/systemd/resolved.conf.d/MultiDirectory.conf"
  [[ -f /etc/salt/minion.append ]] && add_domain_state_reason "Salt minion append file found: /etc/salt/minion.append"
  [[ -f /etc/salt/minion_id ]] && add_domain_state_reason "Salt minion id found: /etc/salt/minion_id"
  [[ -f "$SALT_PKG_MODULE_DST" ]] && add_domain_state_reason "Salt pkg module override found: ${SALT_PKG_MODULE_DST}"

  if [[ "${#DETECTED_DOMAIN_REASONS[@]}" -gt 0 ]]; then
    DETECTED_DOMAIN_STATE="configured"
  fi

  return 0
}

confirm_clean_rejoin_cleanup() {
  local choice

  cat <<EOF

Domain-related configuration was found.
This will remove MultiDirectory domain configuration and restore previous system files.

1) Continue cleanup
2) Cancel and return to main menu
EOF

  while true; do
    printf 'Select an option: '
    IFS= read -r choice || choice=""

    case "$choice" in
      1)
        return 0
        ;;
      2|"")
        return 1
        ;;
      *)
        warn "Invalid option. Please select 1 or 2."
        ;;
    esac
  done
}

need_root_for_cleanup() {
  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Domain cleanup requires root. Run: sudo $0"
    return 1
  fi

  return 0
}

safe_remove_path() {
  local path="$1"

  [[ -n "$path" && "$path" != "/" ]] || return 0
  [[ -e "$path" || -L "$path" ]] || {
    cleanup_log "Skipped absent path: ${path}"
    return 0
  }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: remove ${path}"
    cleanup_log "Dry-run remove: ${path}"
    return 0
  fi

  if rm -rf -- "$path"; then
    cleanup_log "Removed: ${path}"
    return 0
  fi

  error "Failed to remove: ${path}"
  cleanup_log "Failed to remove: ${path}"
  return 1
}

backup_exists_for_path() {
  local path="$1"
  local safe

  safe="$(printf '%s' "$path" | sed 's#/#__#g')"
  [[ -e "${MD_BACKUP_DIR}/${safe}" || -L "${MD_BACKUP_DIR}/${safe}" ]]
}

restore_backup_for_path() {
  local path="$1"
  local safe backup

  safe="$(printf '%s' "$path" | sed 's#/#__#g')"
  backup="${MD_BACKUP_DIR}/${safe}"

  if [[ ! -e "$backup" && ! -L "$backup" ]]; then
    warn "No backup found for: ${path}"
    cleanup_log "Backup not found: ${path}"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: restore ${path} from ${backup}"
    cleanup_log "Dry-run restore: ${path}"
    return 0
  fi

  rm -rf -- "$path"
  mkdir -p "$(dirname "$path")"

  if cp -a "$backup" "$path"; then
    info "Restored: ${path}"
    cleanup_log "Restored: ${path}"
    return 0
  fi

  error "Failed to restore: ${path}"
  cleanup_log "Failed to restore: ${path}"
  return 1
}

stop_domain_services_for_cleanup() {
  local service

  if ! have_cmd systemctl; then
    warn "systemctl not found, skipping service stop"
    cleanup_log "systemctl not found, service stop skipped"
    return 0
  fi

  for service in sssd.service salt-minion.service; do
    if systemctl list-unit-files "$service" >/dev/null 2>&1 || systemctl status "$service" >/dev/null 2>&1; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: stop ${service}"
        cleanup_log "Dry-run stop service: ${service}"
      else
        systemctl stop "$service" 2>/dev/null || true
        cleanup_log "Stopped service if active: ${service}"
      fi
    else
      cleanup_log "Service not present, skipped: ${service}"
    fi
  done
}

remove_managed_files_from_manifest() {
  local path

  if [[ ! -f "$MD_MANIFEST" ]]; then
    warn "Manifest not found, skipping manifest cleanup: ${MD_MANIFEST}"
    cleanup_log "Manifest not found: ${MD_MANIFEST}"
    return 0
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$MD_MANIFEST" ]] && continue
    safe_remove_path "$path" || return 1
  done < "$MD_MANIFEST"
}

restore_original_configs() {
  local path failed=0
  local restore_paths=(
    /etc/krb5.conf
    /etc/nsswitch.conf
    /etc/hostname
    /etc/hosts
    /etc/pam.d/common-auth
    /etc/pam.d/common-account
    /etc/pam.d/common-session
    /etc/pam.d/common-password
    /etc/pam.d/system-auth
    /etc/pam.d/su
    /etc/pam.d/sshd
    /etc/pam.d/gdm-password
    /etc/pam.d/login
    /etc/pam.d/common-login
    /etc/sssd/conf.d
    /etc/salt/minion
  )

  for path in "${restore_paths[@]}"; do
    restore_backup_for_path "$path" || failed=1
  done

  return "$failed"
}

remove_domain_generated_files() {
  local path failed=0
  local generated_paths=(
    /etc/sssd/sssd.conf
    /etc/krb5.keytab
    /etc/sudoers.d/domain-admins
    /etc/ssh/sshd_config.d/ssh_md.conf
    /etc/systemd/resolved.conf.d/MultiDirectory.conf
    /etc/salt/minion.append
    /etc/salt/minion_id
    "$MD_JOIN_ENV"
    "${MD_STATE_DIR}/rollback-in-progress"
    "$MD_MANIFEST"
    "$SALT_PKG_MODULE_DST"
  )

  remove_managed_files_from_manifest || failed=1

  for path in "${generated_paths[@]}"; do
    if backup_exists_for_path "$path"; then
      restore_backup_for_path "$path" || failed=1
    else
      safe_remove_path "$path" || failed=1
    fi
  done

  return "$failed"
}

clear_sssd_cache() {
  local cache_dir

  stop_domain_services_for_cleanup

  for cache_dir in /var/lib/sss/db /var/lib/sss/mc; do
    [[ -d "$cache_dir" ]] || {
      cleanup_log "SSSD cache directory absent: ${cache_dir}"
      continue
    }

    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "Dry-run: clear ${cache_dir}"
      cleanup_log "Dry-run clear SSSD cache: ${cache_dir}"
      continue
    fi

    rm -rf -- "${cache_dir:?}/"* 2>/dev/null || true
    cleanup_log "Cleared SSSD cache: ${cache_dir}"
  done
}

cleanup_empty_domain_dirs() {
  local dir
  local dirs=(
    /var/cache/salt/minion/extmods/modules
    /var/cache/salt/minion/extmods
    /etc/systemd/resolved.conf.d
    "$MD_STATE_DIR"
    "$MD_ETC_DIR"
  )

  [[ "$DRY_RUN" -eq 1 ]] && return 0

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    rmdir "$dir" 2>/dev/null || true
  done
}

reload_services_after_cleanup() {
  if ! have_cmd systemctl; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: reload affected services"
    cleanup_log "Dry-run service reload after cleanup"
    return 0
  fi

  systemctl daemon-reload 2>/dev/null || true
  systemctl restart systemd-resolved.service 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || true
  systemctl restart sshd.service 2>/dev/null || true
  cleanup_log "Reloaded affected services after cleanup"
}

clean_domain_configuration() {
  local failed=0

  need_root_for_cleanup || return 1
  cleanup_log "Clean rejoin cleanup started"

  if [[ -f "$MD_JOIN_ENV" ]]; then
    warn "Managed join state found, remote LDAP cleanup is skipped by clean rejoin workflow"
    cleanup_log "Remote LDAP cleanup skipped; local cleanup will continue"
  else
    cleanup_log "No managed join state found; remote LDAP cleanup skipped"
  fi

  stop_domain_services_for_cleanup
  restore_original_configs || failed=1
  remove_domain_generated_files || failed=1
  clear_sssd_cache
  cleanup_empty_domain_dirs
  reload_services_after_cleanup

  if [[ "$failed" -ne 0 ]]; then
    error "Domain cleanup completed with errors"
    cleanup_log "Clean rejoin cleanup completed with errors"
    return 1
  fi

  info "MultiDirectory domain configuration cleanup completed"
  warn "System reboot is recommended"
  cleanup_log "Clean rejoin cleanup completed successfully"
  return 0
}

rejoin_domain() {
  rejoin_log "Rejoin requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    rejoin_log "configure.sh not found"
    return 1
  fi

  detect_domain_config_state
  rejoin_log "Detected domain config state: ${DETECTED_DOMAIN_STATE}"

  if [[ "$DETECTED_DOMAIN_STATE" == "configured" ]]; then
    warn "Domain-related configuration was found:"
    printf '  - %s\n' "${DETECTED_DOMAIN_REASONS[@]}"
    rejoin_log "Detected config indicators: ${DETECTED_DOMAIN_REASONS[*]}"

    if ! confirm_clean_rejoin_cleanup; then
      warn "Rejoin cleanup cancelled by user"
      rejoin_log "Rejoin cleanup cancelled by user"
      return 0
    fi

    if ! clean_domain_configuration; then
      error "Local domain cleanup failed"
      rejoin_log "Local cleanup failed"
      return 1
    fi

    info "Return to main menu and run Configure domain join when ready"
    rejoin_log "Returning to main menu after cleanup"
    return 0
  fi

  info "No domain-related configuration detected. Starting normal join flow."
  rejoin_log "No domain-related configuration detected; running configure flow"
  run_configure_flow
  local code=$?
  rejoin_log "run_configure_flow exit code: ${code}"
  return "$code"
}

handle_missing_dependencies() {
  error "Dependency validation failed after installation."
  warn "Run 'Install required packages' from the main menu and check the installer log if this repeats."
  warn "Configuration will not install packages automatically."
  return 1
}

run_configure_flow() {
  if check_dependencies; then
    configure_domain
    return $?
  fi

  handle_missing_dependencies
}

show_menu() {
  cat <<EOF

========================================
 Join to Domain
========================================
1) Install required packages
2) Configure domain join
3) Rejoin domain
4) Exit
EOF
}

main_menu() {
  local choice

  while true; do
    show_menu
    printf 'Select an option: '
    IFS= read -r choice || choice=""

    case "$choice" in
      1)
        install_packages
        pause
        ;;
      2)
        run_configure_flow
        pause
        ;;
      3)
        rejoin_domain
        pause
        ;;
      4|q|Q|exit|quit)
        info "Exiting"
        exit 0
        ;;
      "")
        warn "Empty input. Please select a menu item."
        ;;
      *)
        warn "Invalid option. Please select 1, 2, 3 or 4."
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  setup_logging
  main_menu
}

main "$@"
