#!/usr/bin/env bash
set -uo pipefail

REQUIRED_PACKAGES=(
  sssd
  realmd
  adcli
  krb5-user
  oddjob
  oddjob-mkhomedir
  samba-common-bin
)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PACKAGES_SCRIPT="${SCRIPT_DIR}/install_packages.sh"
CONFIGURE_SCRIPT="${SCRIPT_DIR}/configure.sh"
LOG_FILE="/var/log/join-to-domain.log"
DEBUG=0
DRY_RUN=0
LOG_ENABLED=0
PACKAGE_MANAGER=""
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

detect_package_manager() {
  if have_cmd apt-get; then
    PACKAGE_MANAGER="apt"
  elif have_cmd dnf; then
    PACKAGE_MANAGER="dnf"
  elif have_cmd yum; then
    PACKAGE_MANAGER="yum"
  else
    PACKAGE_MANAGER=""
    error "No supported package manager found: apt, dnf or yum"
    return 1
  fi

  debug "Detected package manager: ${PACKAGE_MANAGER}"
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
    sssd)
      printf '%s\n' sssd
      ;;
    realmd)
      printf '%s\n' realm
      ;;
    adcli)
      printf '%s\n' adcli
      ;;
    krb5-user)
      printf '%s\n' kinit klist
      ;;
    oddjob)
      printf '%s\n' oddjobd
      ;;
    oddjob-mkhomedir)
      printf '%s\n' oddjobd
      ;;
    samba-common-bin)
      printf '%s\n' net
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

manager_package_name() {
  local package="$1"

  if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
    printf '%s\n' "$package"
    return 0
  fi

  case "$package" in
    krb5-user)
      printf '%s\n' krb5-workstation
      ;;
    samba-common-bin)
      printf '%s\n' samba-common-tools
      ;;
    *)
      printf '%s\n' "$package"
      ;;
  esac
}

is_package_installed() {
  local package="$1"
  local manager_package

  manager_package="$(manager_package_name "$package")"

  case "$PACKAGE_MANAGER" in
    apt)
      dpkg-query -W -f='${Status}' "$manager_package" 2>/dev/null | grep -q "install ok installed"
      ;;
    dnf|yum)
      rpm -q "$manager_package" >/dev/null 2>&1
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
  local manager_packages=()
  local package failed=0

  if [[ "$#" -gt 0 ]]; then
    packages=("$@")
  else
    packages=("${REQUIRED_PACKAGES[@]}")
  fi

  log "INFO" "Install packages requested: ${packages[*]}"

  if [[ "$#" -eq 0 && -f "$INSTALL_PACKAGES_SCRIPT" ]]; then
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

  if ! need_root_for_install; then
    return 1
  fi

  if [[ "${#packages[@]}" -eq 0 ]]; then
    info "No packages to install"
    return 0
  fi

  for package in "${packages[@]}"; do
    manager_packages+=("$(manager_package_name "$package")")
  done

  case "$PACKAGE_MANAGER" in
    apt)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: apt-get update"
        info "Dry-run: apt-get install -y ${manager_packages[*]}"
      else
        info "Updating package index"
        if ! apt-get update; then
          error "apt-get update failed"
          return 1
        fi

        info "Installing required packages"
        if ! apt-get install -y "${manager_packages[@]}"; then
          error "apt-get install failed"
          return 1
        fi
      fi
      ;;
    dnf|yum)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: ${PACKAGE_MANAGER} install -y ${manager_packages[*]}"
      else
        info "Installing required packages"
        if ! "$PACKAGE_MANAGER" install -y "${manager_packages[@]}"; then
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
    MISSING_PACKAGES=("${REQUIRED_PACKAGES[@]}")
    error "Missing required dependencies"
    printf '\nMissing packages:\n'
    for package in "${MISSING_PACKAGES[@]}"; do
      printf '  - %s\n' "$package"
    done

    return 1
  fi

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

handle_missing_dependencies() {
  local choice

  while true; do
    cat <<EOF

1) Install missing packages
2) Return to main menu
EOF
    printf 'Select an option: '
    IFS= read -r choice || choice=""

    case "$choice" in
      1)
        install_packages "${MISSING_PACKAGES[@]}"
        return $?
        ;;
      2|"")
        return 0
        ;;
      *)
        warn "Invalid option. Please select 1 or 2."
        ;;
    esac
  done
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
3) Exit
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
      3|q|Q|exit|quit)
        info "Exiting"
        exit 0
        ;;
      "")
        warn "Empty input. Please select a menu item."
        ;;
      *)
        warn "Invalid option. Please select 1, 2 or 3."
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
