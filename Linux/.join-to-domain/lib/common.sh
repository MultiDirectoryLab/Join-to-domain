#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="${JOIN_TO_DOMAIN_SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
INTERNAL_DIR="${JOIN_TO_DOMAIN_INTERNAL_DIR:-${SCRIPT_DIR}/.join-to-domain}"
ENV_FILE="${SCRIPT_DIR}/.env"
INSTALL_PACKAGES_SCRIPT="${INTERNAL_DIR}/install_packages.sh"
CONFIGURE_SCRIPT="${INTERNAL_DIR}/configure.sh"
LOG_FILE="/var/log/join-to-domain.log"
REJOIN_LOG_FILE="/var/log/multidirectory-rejoin.log"
MD_CLEANUP_LOG_FILE="/var/log/multidirectory-join.log"
API_CONNECT_TIMEOUT=10
API_MAX_TIME=30
MD_ETC_DIR="/etc/MultiDirectory"
MD_STATE_DIR="${MD_ETC_DIR}/state"
MD_BACKUP_DIR="${MD_STATE_DIR}/backups"
MD_MANIFEST="${MD_STATE_DIR}/manifest"
MD_JOIN_ENV="/etc/MultiDirectory/state/join.env"
SALT_PKG_MODULE_DST="/var/cache/salt/minion/extmods/modules/pkg.py"
MD_GPUPDATE_DST="/usr/local/libexec/multidirectory/md-gpupdate"
MD_GPUPDATE_LINK="/usr/local/bin/md-gpupdate"
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
PAM_SAFETY_OK=0

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

load_env_file() {
  local keys

  [[ -f "$ENV_FILE" ]] || return 0

  if [[ ! -r "$ENV_FILE" ]]; then
    error "Environment file is not readable: ${ENV_FILE}"
    exit 1
  fi

  keys="$(
    sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$ENV_FILE" |
      sort -u |
      tr '\n' ' '
  )"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  export JOIN_TO_DOMAIN_ENV_FILE="$ENV_FILE"
  export JOIN_TO_DOMAIN_ENV_KEYS=" ${keys} "
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

  printf '\n%s ' "$(tr_text prompt.press_enter)"
  read_clean_input _ || true
}

validate_utf8_input() {
  local value="$1"

  if have_cmd iconv; then
    printf '%s' "$value" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
    return $?
  fi

  return 0
}

sanitize_input() {
  local value="$1"

  value="${value//$'\r'/}"
  value="$(
    printf '%s' "$value" |
      LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' |
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
  )"

  printf '%s' "$value"
}

read_clean_input() {
  local var="$1"
  local raw cleaned

  if [[ -t 0 && -r /dev/tty ]]; then
    stty echo < /dev/tty 2>/dev/null || true
  fi

  printf -v "$var" '%s' ""

  IFS= read -r raw || raw=""
  cleaned="$(sanitize_input "$raw")"

  if ! validate_utf8_input "$cleaned"; then
    printf -v "$var" '%s' ""
    return 1
  fi

  printf -v "$var" '%s' "$cleaned"
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

find_executable() {
  local binary="$1"
  local dir

  if have_cmd "$binary"; then
    command -v "$binary"
    return 0
  fi

  for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    if [[ -x "${dir}/${binary}" ]]; then
      printf '%s\n' "${dir}/${binary}"
      return 0
    fi
  done

  return 1
}

have_executable() {
  find_executable "$1" >/dev/null 2>&1
}

load_os_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-${OS_ID:-unknown}}"
  OS_VARIANT_ID="${VARIANT_ID:-}"
}

is_astra_linux() {
  [[ "${OS_ID}" == "astra" ]]
}

is_astra_se() {
  is_astra_linux && [[ "${OS_VARIANT_ID}" == "se" ]]
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
