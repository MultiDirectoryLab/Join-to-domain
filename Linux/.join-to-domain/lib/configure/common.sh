#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="${JOIN_TO_DOMAIN_INTERNAL_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
FILES_DIR="${SCRIPT_DIR}/files"
PUBLIC_LAUNCHER="./join-to-domain.sh"

KRB5_SRC="${FILES_DIR}/krb5.conf"
NSSWITCH_SRC="${FILES_DIR}/nsswitch.conf"
SSH_MD_SRC="${FILES_DIR}/ssh_md.conf"
SSSD_CONF_D_SRC="${FILES_DIR}/sssd.conf.d"
DEFAULT_SSSD_SRC="${SSSD_CONF_D_SRC}/default-sssd.conf"
ASTRA_PARSEC_SSSD_SRC="${SSSD_CONF_D_SRC}/astra-se-parsec-sssd.conf"
PAM_D_SRC="${FILES_DIR}/pam.d"
SUDOERS_D_SRC="${FILES_DIR}/sudoers.d"
RESOLVED_CONF_D_SRC="${FILES_DIR}/resolved.conf.d"
ACCOUNTSERVICE_HELPER_SRC="${FILES_DIR}/accountsservice/md-cache-accountsservice-user"
ACCOUNTSERVICE_HELPER_DST="/usr/local/sbin/md-cache-accountsservice-user"
PROFILE_D_SRC="${FILES_DIR}/profile.d"
SALT_SRC="${FILES_DIR}/salt"
SALT_MODULES_SRC="${FILES_DIR}/_modules"
SALT_MINION_EXTMODS_MODULES_DIR="/var/cache/salt/minion/extmods/modules"
SALT_PKG_MODULE_SRC="${SALT_MODULES_SRC}/pkg.py"
SALT_PKG_MODULE_DST="${SALT_MINION_EXTMODS_MODULES_DIR}/pkg.py"
MD_GPUPDATE_SRC="${FILES_DIR}/md-gpupdate"
MD_GPUPDATE_DST="/usr/local/libexec/multidirectory/md-gpupdate"
MD_GPUPDATE_LINK="/usr/local/bin/md-gpupdate"

MD_ETC_DIR="/etc/MultiDirectory"
MD_STATE_DIR="${MD_ETC_DIR}/state"
MD_BACKUP_DIR="${MD_STATE_DIR}/backups"
MD_MANIFEST="${MD_STATE_DIR}/manifest"
MD_JOIN_ENV="${MD_STATE_DIR}/join.env"
MD_ROLLBACK_MARKER="${MD_STATE_DIR}/rollback-in-progress"
MD_NM_DNS_STATE="${MD_STATE_DIR}/networkmanager-dns.env"
MD_AUTHSELECT_STATE="${MD_STATE_DIR}/authselect.profile"
MD_SSSD_SOCKET_STATE="${MD_STATE_DIR}/sssd-sockets.state"

INSTALL_STATE_DIR="/var/lib/MultiDirectory/install"
INSTALL_ENV="${INSTALL_STATE_DIR}/install.env"

LOG_FILE="/var/log/multidirectory-join.log"
API_CONNECT_TIMEOUT=10
API_MAX_TIME=30
SALT_ACCEPT_CONNECT_TIMEOUT=5
SALT_ACCEPT_MAX_TIME=10

log() {
  printf '[DETAIL] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
  printf '%b\n' "${BLUE}[INFO]${NC} $*" > /dev/tty
  printf '[INFO] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

ok() {
  printf '%b\n' "${GREEN}[OK]${NC} $*" > /dev/tty
  printf '[OK] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
  printf '%b\n' "${YELLOW}[WARN]${NC} $*" > /dev/tty
  printf '[WARN] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
  printf '%b\n' "${RED}[ERROR]${NC} $*" > /dev/tty
  printf '[ERROR] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
  printf '%b\n' "${BLUE}[INFO]${NC} Full log: ${LOG_FILE}" > /dev/tty
  printf '[INFO] Full log: %s\n' "$LOG_FILE" >> "$LOG_FILE" 2>/dev/null || true

  if [[ "${MD_JOIN_ROLLBACK_ACTIVE:-0}" -eq 1 ]] && declare -F rollback_local_changes >/dev/null 2>&1; then
    MD_JOIN_ROLLBACK_ACTIVE=0
    trap - ERR
    rollback_local_changes 1
  fi

  exit 1
}

tty_echo() {
  printf '%b\n' "$*" > /dev/tty
}

usage() {
  if [[ -w /dev/tty ]]; then
    echo "Use: sudo ${PUBLIC_LAUNCHER}" > /dev/tty
  else
    echo "Use: sudo ${PUBLIC_LAUNCHER}" >&2
  fi
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo ${PUBLIC_LAUNCHER}"
  fi
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  log "Log file: ${LOG_FILE}"
  log "State directory: ${MD_STATE_DIR}"
  log "Install state file: ${INSTALL_ENV}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
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

need_file() {
  local display_path="$1"

  if [[ "$1" == "$SCRIPT_DIR"/* ]]; then
    display_path="${1#"$SCRIPT_DIR"/}"
  fi

  if [[ ! -f "$1" ]]; then
    [[ "$1" == "$SCRIPT_DIR"/* ]] && die "$(ui_text "Required internal file not found: ${display_path}" "Не найден внутренний файл: ${display_path}")"
    die "File not found: $1"
  fi

  if [[ ! -s "$1" ]]; then
    [[ "$1" == "$SCRIPT_DIR"/* ]] && die "$(ui_text "Required internal file is empty: ${display_path}" "Внутренний файл пуст: ${display_path}")"
    die "File is empty: $1"
  fi
}

need_dir() {
  local display_path="$1"

  if [[ "$1" == "$SCRIPT_DIR"/* ]]; then
    display_path="${1#"$SCRIPT_DIR"/}"
  fi

  if [[ ! -d "$1" ]]; then
    [[ "$1" == "$SCRIPT_DIR"/* ]] && die "$(ui_text "Required internal directory not found: ${display_path}" "Не найден внутренний каталог: ${display_path}")"
    die "Directory not found: $1"
  fi
}

read_tty() {
  local var="$1"
  local prompt="$2"

  printf '%b ' "${YELLOW}${prompt}${NC}" > /dev/tty
  if ! read_clean_input "$var" < /dev/tty; then
    warn "Input contains invalid characters. Please enter the value again."
  fi

  printf '[INPUT] %s %s\n' "$prompt" "${!var}" >> "$LOG_FILE" 2>/dev/null || true
}

read_secret_tty() {
  local var="$1"
  local prompt="$2"

  printf -v "$var" '%s' ""
  printf '%b ' "${YELLOW}${prompt}${NC}" > /dev/tty
  IFS= read -rs "$var" < /dev/tty
  printf '\n' > /dev/tty

  printf '[INPUT] %s ********\n' "$prompt" >> "$LOG_FILE" 2>/dev/null || true
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
  local saved_edition="${EDITION-}"
  local edition_was_set=0

  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  [[ "${EDITION+x}" == "x" ]] && edition_was_set=1

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-${OS_ID}}"
  OS_VARIANT_ID="${VARIANT_ID:-}"

  if [[ "$edition_was_set" -eq 1 ]]; then
    EDITION="$saved_edition"
  else
    unset EDITION
  fi
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

is_redos_or_rhel_like() {
  [[ "${OS_ID}" =~ ^(redos|rhel|centos|rocky|almalinux|fedora)$ ]] || [[ "${OS_LIKE}" =~ (rhel|fedora) ]]
}

is_altlinux() {
  [[ "${OS_ID}" == "altlinux" ]] || [[ "${OS_LIKE}" =~ (altlinux|sisyphus) ]]
}

check_system_capabilities() {
  need_cmd systemctl

  if ! systemctl list-unit-files >/dev/null 2>&1; then
    die "systemd is not available or not running"
  fi
}

salt_minion_unit_exists() {
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl cat salt-minion.service >/dev/null 2>&1
}

print_salt_diagnostics() {
  warn "Salt minion diagnostics:"

  if have_cmd salt-minion; then
    salt-minion --version 2>/dev/null | sed 's/^/  binary: /' || true
  else
    warn "salt-minion binary not found in PATH"
  fi

  if have_cmd dpkg-query; then
    dpkg-query -W -f='  dpkg: ${binary:Package} ${Version} ${Status}\n' 'salt*' 2>/dev/null || true
  fi

  if have_cmd rpm; then
    rpm -qa | grep -Ei '^salt|minion' | sed 's/^/  rpm: /' || true
  fi

  systemctl list-unit-files 2>/dev/null | grep -E '^salt|minion' | sed 's/^/  unit: /' || true

  if [[ -f /etc/salt/minion_id ]]; then
    sed 's/^/  minion_id: /' /etc/salt/minion_id 2>/dev/null || true
  fi

  grep -RniE '^\s*id\s*:' /etc/salt 2>/dev/null | sed 's/^/  config-id: /' || true
}

require_salt_minion_ready() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || return 0

  if ! have_cmd salt-minion; then
    print_salt_diagnostics
    die "salt-minion command not found. Run package installation from ${PUBLIC_LAUNCHER} and check local Salt package."
  fi

  if ! salt_minion_unit_exists; then
    print_salt_diagnostics
  fi

}

restart_salt_minion_or_die() {
  require_salt_minion_ready

  systemctl daemon-reload || true
  systemctl enable salt-minion.service >/dev/null 2>&1 || true
  systemctl restart salt-minion.service || {
    systemctl status salt-minion.service --no-pager -l 2>/dev/null || true
    die "Failed to restart salt-minion.service"
  }

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

md_init_state() {
  mkdir -p "${MD_STATE_DIR}" "${MD_BACKUP_DIR}"
  touch "${MD_MANIFEST}"
  chmod 700 "${MD_STATE_DIR}"
  chmod 700 "${MD_BACKUP_DIR}"
  chmod 600 "${MD_MANIFEST}"
}

md_track() {
  local path="$1"

  [[ -n "$path" ]] || return 0

  grep -Fxq "$path" "${MD_MANIFEST}" 2>/dev/null || echo "$path" >> "${MD_MANIFEST}"
}

md_backup_once() {
  local path="$1"
  local safe

  safe="$(echo "$path" | sed 's#/#__#g')"

  if [[ -e "$path" || -L "$path" ]]; then
    if [[ ! -e "${MD_BACKUP_DIR}/${safe}" && ! -L "${MD_BACKUP_DIR}/${safe}" ]]; then
      cp -a "$path" "${MD_BACKUP_DIR}/${safe}"
      log "Backup created: $path"
    fi
  fi
}

md_backup_exists() {
  local path="$1"
  local safe

  safe="$(echo "$path" | sed 's#/#__#g')"
  [[ -e "${MD_BACKUP_DIR}/${safe}" || -L "${MD_BACKUP_DIR}/${safe}" ]]
}

restore_one() {
  local path="$1"
  local safe

  safe="$(echo "$path" | sed 's#/#__#g')"

  if [[ -e "${MD_BACKUP_DIR}/${safe}" || -L "${MD_BACKUP_DIR}/${safe}" ]]; then
    rm -rf "$path"
    mkdir -p "$(dirname -- "$path")"
    cp -a "${MD_BACKUP_DIR}/${safe}" "$path"
    log "Restored: $path"
  fi
}

install_local_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0644}"

  need_file "$src"

  mkdir -p "$(dirname "$dst")"
  md_backup_once "$dst"

  install -m "$mode" -o root -g root "$src" "$dst"
  md_track "$dst"

  log "Installed: $dst"
}

copy_dir_files() {
  local src_dir="$1"
  local dst_dir="$2"
  local mode="${3:-0644}"
  local basename

  need_dir "$src_dir"
  mkdir -p "$dst_dir"

  shopt -s nullglob
  local files=("${src_dir}"/*)
  shopt -u nullglob

  for src in "${files[@]}"; do
    [[ -f "$src" ]] || continue
    basename="$(basename "$src")"
    if [[ "$src_dir" == "$SALT_SRC" && "$basename" == "minion.append" ]]; then
      log "Skipped static Salt template: ${src}"
      continue
    fi
    install_local_file "$src" "${dst_dir}/${basename}" "$mode"
  done
}
