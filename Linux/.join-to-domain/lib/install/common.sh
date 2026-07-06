#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

tty_echo() {
  echo -e "$*" > /dev/tty
}

SCRIPT_DIR="${JOIN_TO_DOMAIN_INTERNAL_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
FILES_DIR="${SCRIPT_DIR}/files"
DEB_DIR="${FILES_DIR}/deb"
RPM_DIR="${FILES_DIR}/rpm"
CONFIGURE_SCRIPT="${SCRIPT_DIR}/configure.sh"
PUBLIC_LAUNCHER="./join-to-domain.sh"

MD_JOIN_ENV="/etc/MultiDirectory/state/join.env"

LOG_FILE="/var/log/multidirectory-install-packages.log"

DEB_REQUIRED_PACKAGES=(
  ca-certificates
  curl
  jq
  file
  sudo
  ldap-utils
  krb5-user
  sssd
  sssd-tools
  libnss-sss
  libpam-sss
  libpam-modules
  oddjob
  oddjob-mkhomedir
  openssh-server
)

RPM_REQUIRED_PACKAGES=(
  ca-certificates
  curl
  jq
  file
  sudo
  openldap-clients
  krb5-workstation
  sssd
  sssd-tools
  sssd-client
  oddjob
  oddjob-mkhomedir
  openssh-server
)

RPM_APT_REQUIRED_PACKAGES=(
  ca-certificates
  curl
  jq
  file
  sudo
  openldap-clients
  krb5-workstation
  sssd
  sssd-tools
  openssh-server
)

STATE_DIR="/var/lib/MultiDirectory/install"
PKGS_BEFORE="${STATE_DIR}/packages-before.list"
PKGS_AFTER="${STATE_DIR}/packages-after.list"
PKGS_INSTALLED="${STATE_DIR}/packages-installed-by-script.list"
LOCAL_PKGS_INSTALLED="${STATE_DIR}/local-packages-installed-by-script.list"
PACKAGES_TO_REMOVE="${STATE_DIR}/packages-to-remove.list"
INSTALL_ENV="${STATE_DIR}/install.env"

usage() {
  echo "Use: sudo ${PUBLIC_LAUNCHER}"
  exit 1
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  exec > >(tee -a "$LOG_FILE") 2>&1

  log "Log file: ${LOG_FILE}"
  log "State directory: ${STATE_DIR}"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo ${PUBLIC_LAUNCHER}"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
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

  printf -v "$var" '%s' ""

  IFS= read -r raw || raw=""
  cleaned="$(sanitize_input "$raw")"

  if ! validate_utf8_input "$cleaned"; then
    printf -v "$var" '%s' ""
    return 1
  fi

  printf -v "$var" '%s' "$cleaned"
}

read_tty() {
  local var="$1"
  local prompt="$2"

  echo -ne "${YELLOW}${prompt}${NC} " > /dev/tty
  if ! read_clean_input "$var" < /dev/tty; then
    warn "Input contains invalid characters. Please enter the value again."
  fi
}

env_has_key() {
  [[ "${JOIN_TO_DOMAIN_ENV_KEYS:-}" == *" $1 "* ]]
}

use_env_edition_if_available() {
  if [[ "${EDITION:-}" == "enterprise" ]]; then
    WITH_SALT=1
    log "Using edition from environment: Enterprise"
    return 0
  fi

  if [[ "${EDITION:-}" == "community" ]]; then
    WITH_SALT=0
    log "Using edition from environment: Community"
    return 0
  fi

  if env_has_key WITH_SALT; then
    case "${WITH_SALT:-}" in
      1)
        EDITION="enterprise"
        log "Using edition from environment: Enterprise"
        return 0
        ;;
      0)
        EDITION="community"
        log "Using edition from environment: Community"
        return 0
        ;;
      *)
        warn "Invalid WITH_SALT in environment. Enter 1 or 0."
        ;;
    esac
  fi

  if env_has_key EDITION; then
    warn "Invalid EDITION in environment. Enter enterprise or community."
  fi

  return 1
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-${OS_ID}}"
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
  if is_altlinux && have_cmd apt-get; then
    PM="apt-get"
  elif have_cmd dnf; then
    PM="dnf"
  elif have_cmd yum; then
    PM="yum"
  elif have_cmd apt-get; then
    PM="apt-get"
  else
    die "No supported package manager found: dnf/yum/apt-get"
  fi

  if [[ "${LIST_REQUIRED_PACKAGES_MODE:-0}" != "1" ]]; then
    log "Package manager: ${PM}"
  fi
}

normalize_lf() {
  local path="$1"

  [[ -f "$path" ]] || return 0

  if file "$path" | grep -q "CRLF"; then
    warn "Converting CRLF to LF: $path"
    sed -i 's/\r$//' "$path"
  fi
}

normalize_files_eol() {
  if [[ -d "$FILES_DIR" ]]; then
    while IFS= read -r -d '' file_path; do
      normalize_lf "$file_path"
    done < <(find "$FILES_DIR" -type f -print0)
  fi

  normalize_lf "$0"
}

init_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  touch "$LOCAL_PKGS_INSTALLED"
  chmod 600 "$LOCAL_PKGS_INSTALLED"
}
