#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PACKAGES_SCRIPT="${SCRIPT_DIR}/install_packages.sh"
CONFIGURE_SCRIPT="${SCRIPT_DIR}/configure.sh"
LOG_FILE="/var/log/join-to-domain.log"
REJOIN_LOG_FILE="/var/log/multidirectory-rejoin.log"
MD_JOIN_ENV="/etc/MultiDirectory/state/join.env"
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

domain_state_reason() {
  if [[ -f "$MD_JOIN_ENV" ]]; then
    printf 'MultiDirectory join state found: %s\n' "$MD_JOIN_ENV"
    return 0
  fi

  if have_cmd realm && realm list 2>/dev/null | grep -q '^[^[:space:]]'; then
    printf 'realm reports configured domain membership\n'
    return 0
  fi

  if [[ -f /etc/sssd/sssd.conf ]] && grep -Eq '^\[domain/[^]]+\]' /etc/sssd/sssd.conf 2>/dev/null; then
    printf 'SSSD domain configuration found: /etc/sssd/sssd.conf\n'
    return 0
  fi

  return 1
}

is_domain_joined() {
  domain_state_reason >/dev/null
}

confirm_rejoin_leave() {
  local choice

  cat <<EOF

Machine is currently joined to a domain.
Do you want to leave the domain before rejoining?

1) Yes
2) No
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

leave_domain_for_rejoin() {
  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Domain leave requires root. Run: sudo $0"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -f "$MD_JOIN_ENV" ]]; then
      info "Dry-run: MD_CALLED_FROM_INSTALL_PACKAGES=1 bash ${CONFIGURE_SCRIPT} leave"
    elif have_cmd realm; then
      info "Dry-run: realm leave"
    else
      warn "Dry-run: no safe leave backend detected"
    fi
    return 0
  fi

  if [[ -f "$MD_JOIN_ENV" ]]; then
    rejoin_log "Leaving managed MultiDirectory domain using configure.sh leave"
    MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" leave
    local code=$?
    rejoin_log "configure.sh leave exit code: ${code}"
    return "$code"
  fi

  if have_cmd realm && realm list 2>/dev/null | grep -q '^[^[:space:]]'; then
    rejoin_log "Leaving domain using realm leave"
    realm leave
    local code=$?
    rejoin_log "realm leave exit code: ${code}"

    if [[ "$code" -eq 0 ]] && have_cmd systemctl; then
      systemctl stop sssd.service 2>/dev/null || true
      rejoin_log "sssd.service stopped after realm leave"
    fi

    return "$code"
  fi

  error "Domain-like SSSD configuration found, but no managed join state or realm backend is available."
  warn "Rejoin aborted to avoid destroying existing SSSD configuration without a safe leave mechanism."
  rejoin_log "Leave aborted: no safe leave backend"
  return 1
}

ensure_dependencies_for_rejoin() {
  if check_dependencies; then
    rejoin_log "Dependency validation succeeded"
    return 0
  fi

  rejoin_log "Dependencies are missing, running install step"
  install_packages || return 1

  if [[ "$DRY_RUN" -eq 1 ]]; then
    rejoin_log "Dry-run mode: dependency recheck skipped after simulated install"
    return 0
  fi

  check_dependencies
}

rejoin_domain() {
  local reason

  rejoin_log "Rejoin requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    rejoin_log "configure.sh not found"
    return 1
  fi

  if reason="$(domain_state_reason)"; then
    warn "$reason"
    rejoin_log "Domain detected: ${reason}"

    if ! confirm_rejoin_leave; then
      warn "Rejoin cancelled by user"
      rejoin_log "Rejoin cancelled by user"
      return 0
    fi

    if ! leave_domain_for_rejoin; then
      error "Domain leave failed. Rejoin aborted."
      rejoin_log "Leave failed, rejoin aborted"
      return 1
    fi

    rejoin_log "Leave completed"
  else
    info "Machine is not joined to a domain. Starting normal join flow."
    rejoin_log "No domain membership detected"
  fi

  ensure_dependencies_for_rejoin || {
    error "Dependency validation failed. Rejoin aborted."
    rejoin_log "Dependency validation failed after install attempt"
    return 1
  }

  configure_domain
  local code=$?
  rejoin_log "configure_domain exit code: ${code}"
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
