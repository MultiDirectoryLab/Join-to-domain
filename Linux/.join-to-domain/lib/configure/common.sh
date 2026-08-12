#!/usr/bin/env bash
set -Eeuo pipefail

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
MD_BACKUPS_ROOT="${MD_ETC_DIR}/backups"
MD_BACKUP_DIR=""
MD_MANIFEST=""
MD_JOIN_ENV="${MD_STATE_DIR}/join.env"
MD_PENDING_BACKUP="${MD_STATE_DIR}/active-backup"
MD_ROLLBACK_MARKER="${MD_STATE_DIR}/rollback-in-progress"
MD_NM_DNS_STATE="${MD_STATE_DIR}/networkmanager-dns.env"
MD_OPERATION_NM_DNS_STATE=""
MD_AUTHSELECT_STATE="${MD_STATE_DIR}/authselect.profile"
MD_SSSD_SOCKET_STATE="${MD_STATE_DIR}/sssd-sockets.state"
MD_ACTIVITY_PID=""

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

activity_clear_line() {
  if [[ -n "${MD_ACTIVITY_PID:-}" ]]; then
    printf '\r\033[K' > /dev/tty 2>/dev/null || true
  fi
}

activity_stop() {
  if [[ -n "${MD_ACTIVITY_PID:-}" ]]; then
    kill "$MD_ACTIVITY_PID" 2>/dev/null || true
    wait "$MD_ACTIVITY_PID" 2>/dev/null || true
    printf '\r\033[K' > /dev/tty 2>/dev/null || true
    MD_ACTIVITY_PID=""
  fi
  return 0
}

activity_start() {
  local message

  activity_stop
  message="$(runtime_text "$*")"
  printf '[INFO] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
  [[ -t 0 && -w /dev/tty ]] || return 0

  (
    local frame=0
    local -a frames=('|' '/' '-' "\\")
    trap 'exit 0' INT TERM
    while true; do
      printf '\r%b[%s]%b %s' "$BLUE" "${frames[$frame]}" "$NC" "$message" > /dev/tty
      frame=$(( (frame + 1) % ${#frames[@]} ))
      sleep 0.2
    done
  ) &
  MD_ACTIVITY_PID=$!
}

info() {
  local message="$(runtime_text "$*")"
  printf '[INFO] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

ok() {
  local message="$(runtime_text "$*")"
  printf '[OK] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

user_info() {
  local message="$(runtime_text "$*")"
  activity_stop
  printf '%b\n' "${BLUE}[INFO]${NC} ${message}" > /dev/tty
  printf '[INFO] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

user_ok() {
  local message="$(runtime_text "$*")"
  activity_stop
  printf '%b\n' "${GREEN}[OK]${NC} ${message}" > /dev/tty
  printf '[OK] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
  local message="$(runtime_text "$*")"
  activity_clear_line
  printf '%b\n' "${YELLOW}[WARN]${NC} ${message}" > /dev/tty
  printf '[WARN] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
  local message="$(runtime_text "$*")"
  activity_stop
  printf '%b\n' "${RED}[ERROR]${NC} ${message}" > /dev/tty
  printf '[ERROR] %s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
  printf '%b\n' "${BLUE}[INFO]${NC} Full log: ${LOG_FILE}" > /dev/tty
  printf '[INFO] Full log: %s\n' "$LOG_FILE" >> "$LOG_FILE" 2>/dev/null || true

  local rollback_handler="${MD_ROLLBACK_HANDLER:-rollback_local_changes}"
  if [[ "${MD_JOIN_ROLLBACK_ACTIVE:-0}" -eq 1 ]] && declare -F "$rollback_handler" >/dev/null 2>&1; then
    MD_JOIN_ROLLBACK_ACTIVE=0
    trap - ERR INT TERM
    "$rollback_handler" 1
  fi

  exit 1
}

tty_echo() {
  activity_stop
  printf '%b\n' "$*" > /dev/tty
}

usage() {
  if [[ -w /dev/tty ]]; then
    echo "$(ui_text "Use" "Использование"): sudo ${PUBLIC_LAUNCHER}" > /dev/tty
  else
    echo "$(ui_text "Use" "Использование"): sudo ${PUBLIC_LAUNCHER}" >&2
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

  activity_stop
  printf '%b ' "${YELLOW}${prompt}${NC}" > /dev/tty
  if ! read_clean_input "$var" < /dev/tty; then
    warn "Input contains invalid characters. Please enter the value again."
  fi

  printf '[INPUT] %s %s\n' "$prompt" "${!var}" >> "$LOG_FILE" 2>/dev/null || true
}

read_secret_tty() {
  local var="$1"
  local prompt="$2"

  activity_stop
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
  warn "$(ui_text "Salt minion failed; diagnostics were written to ${LOG_FILE}" "Ошибка Salt minion; диагностика записана в ${LOG_FILE}")"

  printf '[DETAIL] Salt minion diagnostics:\n' >> "$LOG_FILE"

  if have_cmd salt-minion; then
    salt-minion --version 2>/dev/null | sed 's/^/  binary: /' >> "$LOG_FILE" || true
  else
    printf '  salt-minion binary not found in PATH\n' >> "$LOG_FILE"
  fi

  if have_cmd dpkg-query; then
    dpkg-query -W -f='  dpkg: ${binary:Package} ${Version} ${Status}\n' 'salt*' >> "$LOG_FILE" 2>/dev/null || true
  fi

  if have_cmd rpm; then
    rpm -qa | grep -Ei '^salt|minion' | sed 's/^/  rpm: /' >> "$LOG_FILE" || true
  fi

  systemctl list-unit-files 2>/dev/null | grep -E '^salt|minion' | sed 's/^/  unit: /' >> "$LOG_FILE" || true

  if [[ -f /etc/salt/minion_id ]]; then
    sed 's/^/  minion_id: /' /etc/salt/minion_id >> "$LOG_FILE" 2>/dev/null || true
  fi

  grep -RniE '^\s*id\s*:' /etc/salt 2>/dev/null | sed 's/^/  config-id: /' >> "$LOG_FILE" || true
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

  systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
  systemctl enable salt-minion.service >/dev/null 2>&1 || true
  systemctl restart salt-minion.service >> "$LOG_FILE" 2>&1 || {
    systemctl status salt-minion.service --no-pager -l >> "$LOG_FILE" 2>&1 || true
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

managed_join_paths() {
  printf '%s\n' \
    /etc/krb5.conf /etc/krb5.keytab /etc/nsswitch.conf \
    /etc/sssd/sssd.conf /etc/sssd/conf.d \
    /etc/pam.d/system-auth /etc/pam.d/su /etc/pam.d/sshd \
    /etc/pam.d/gdm-password /etc/pam.d/login /etc/pam.d/common-login \
    /etc/pam.d/password-auth /etc/pam.d/fingerprint-auth \
    /etc/pam.d/smartcard-auth /etc/pam.d/postlogin \
    /etc/pam.d/common-auth /etc/pam.d/common-account \
    /etc/pam.d/common-session /etc/pam.d/common-password \
    /etc/ssh/sshd_config.d/ssh_md.conf /etc/sudoers.d/domain-admins \
    /etc/systemd/resolved.conf.d/MultiDirectory.conf \
    /etc/salt/minion /etc/salt/minion.append /etc/salt/minion_id \
    /etc/salt/pki/minion /etc/profile.d/multidirectory-prompt.sh \
    /usr/local/sbin/md-cache-accountsservice-user /usr/bin/sudo \
    "$SALT_PKG_MODULE_DST" "$MD_GPUPDATE_DST" "$MD_GPUPDATE_LINK" \
    /etc/parsec/mswitch.conf /etc/hostname /etc/hosts /etc/resolv.conf
}

backup_key() {
  printf 'FILE_%s' "$(printf '%s' "$1" | sed 's#^/##; s#[^A-Za-z0-9]#_#g' | tr '[:lower:]' '[:upper:]')"
}

create_backup_set() {
  local kind="$1"
  local stamp candidate=0 path key rel existed

  mkdir -p "$MD_STATE_DIR" "$MD_BACKUPS_ROOT"
  chmod 700 "$MD_STATE_DIR" "$MD_BACKUPS_ROOT"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  MD_BACKUP_DIR="${MD_BACKUPS_ROOT}/${kind}-${stamp}"
  while [[ -e "$MD_BACKUP_DIR" ]]; do
    candidate=$((candidate + 1))
    MD_BACKUP_DIR="${MD_BACKUPS_ROOT}/${kind}-${stamp}-${candidate}"
  done
  MD_MANIFEST="${MD_BACKUP_DIR}/manifest.env"
  mkdir -p "$MD_BACKUP_DIR/files"
  chmod 700 "$MD_BACKUP_DIR" "$MD_BACKUP_DIR/files"
  {
    printf 'BACKUP_VERSION=1\n'
    printf 'BACKUP_KIND=%q\n' "$kind"
    printf 'CREATED_AT=%q\n' "$(date --iso-8601=seconds)"
    printf 'BACKUP_DIR=%q\n' "$MD_BACKUP_DIR"
  } > "$MD_MANIFEST"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    key="$(backup_key "$path")"
    rel="${path#/}"
    existed=0
    if [[ -e "$path" || -L "$path" ]]; then
      mkdir -p "$MD_BACKUP_DIR/files/$(dirname "$rel")"
      cp -a -- "$path" "$MD_BACKUP_DIR/files/$rel" || return 1
      existed=1
    fi
    printf '%s_PATH=%q\n%s_EXISTED=%s\n%s_BACKUP=%q\n' \
      "$key" "$path" "$key" "$existed" "$key" "files/$rel" >> "$MD_MANIFEST"
  done < <(managed_join_paths | awk '!seen[$0]++')
  chmod 600 "$MD_MANIFEST"
  printf '%s\n' "$MD_BACKUP_DIR" > "$MD_PENDING_BACKUP"
  chmod 600 "$MD_PENDING_BACKUP"
  log "${kind} backup created: ${MD_BACKUP_DIR}"
}

create_join_backup() {
  MD_OPERATION_NM_DNS_STATE=""
  create_backup_set join
}

create_recovery_backup() {
  create_backup_set rejoin || return 1
  MD_OPERATION_NM_DNS_STATE="${MD_BACKUP_DIR}/networkmanager-dns.env"
  # join.env is not part of the static managed-path list because older
  # pre-Join backups must remain valid. Capture it dynamically for Rejoin so
  # an interrupted/failed refresh restores the previous saved state as well.
  md_backup_once "$MD_JOIN_ENV"
}

legacy_backup_safe_name() {
  printf '%s' "${1//\//__}"
}

legacy_manifest_path_is_safe() {
  local path="$1"

  [[ "$path" == /* ]] || return 1
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  case "/${path#/}/" in
    */../*|*/./*) return 1 ;;
  esac
  return 0
}

migrate_legacy_prejoin_backup() {
  local legacy_manifest="${MD_STATE_DIR}/manifest"
  local legacy_backup_dir="${MD_STATE_DIR}/backups"
  local stamp candidate=0 migrated_dir migrated_manifest
  local path key rel existed legacy_safe tmp_join_env

  [[ -f "$MD_JOIN_ENV" && -r "$legacy_manifest" && -d "$legacy_backup_dir" ]] || return 1

  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    legacy_manifest_path_is_safe "$path" || {
      warn "Legacy join manifest contains an unsafe path: ${path}"
      return 1
    }
  done < "$legacy_manifest"

  mkdir -p "$MD_BACKUPS_ROOT"
  chmod 700 "$MD_BACKUPS_ROOT"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  migrated_dir="${MD_BACKUPS_ROOT}/join-${stamp}-legacy"
  while [[ -e "$migrated_dir" ]]; do
    candidate=$((candidate + 1))
    migrated_dir="${MD_BACKUPS_ROOT}/join-${stamp}-legacy-${candidate}"
  done
  migrated_manifest="${migrated_dir}/manifest.env"
  mkdir -p "$migrated_dir/files"
  chmod 700 "$migrated_dir" "$migrated_dir/files"
  {
    printf 'BACKUP_VERSION=1\n'
    printf 'BACKUP_KIND=join\n'
    printf 'CREATED_AT=%q\n' "$(date --iso-8601=seconds)"
    printf 'BACKUP_DIR=%q\n' "$migrated_dir"
    printf 'MIGRATED_FROM=%q\n' "$legacy_manifest"
  } > "$migrated_manifest"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    # State metadata is removed as a unit after Leave and must never be
    # restored recursively from inside its own backup.
    case "$path" in "$MD_ETC_DIR"|"$MD_ETC_DIR"/*) continue ;; esac

    key="$(backup_key "$path")"
    rel="${path#/}"
    existed=0
    legacy_safe="$(legacy_backup_safe_name "$path")"

    if grep -Fxq "$path" "$legacy_manifest"; then
      if [[ -e "$legacy_backup_dir/$legacy_safe" || -L "$legacy_backup_dir/$legacy_safe" ]]; then
        mkdir -p "$migrated_dir/files/$(dirname "$rel")"
        cp -a -- "$legacy_backup_dir/$legacy_safe" "$migrated_dir/files/$rel" || return 1
        existed=1
      fi
    elif [[ -e "$path" || -L "$path" ]]; then
      # The old Join did not touch this path. Preserve its current value so
      # the expanded path list in the new format cannot delete it on Leave.
      mkdir -p "$migrated_dir/files/$(dirname "$rel")"
      cp -a -- "$path" "$migrated_dir/files/$rel" || return 1
      existed=1
    fi

    printf '%s_PATH=%q\n%s_EXISTED=%s\n%s_BACKUP=%q\n' \
      "$key" "$path" "$key" "$existed" "$key" "files/$rel" >> "$migrated_manifest"
  done < <(
    {
      managed_join_paths
      sed -n '/^[[:space:]]*\//p' "$legacy_manifest"
    } | awk '!seen[$0]++'
  )
  chmod 600 "$migrated_manifest"

  MD_BACKUP_DIR="$migrated_dir"
  MD_MANIFEST="$migrated_manifest"
  validate_join_backup || return 1

  # Only publish the migrated backup after it is complete. Replace an empty
  # legacy key as well as handling files that did not contain the key at all.
  tmp_join_env="$(mktemp "${MD_STATE_DIR}/join.env.migrate.XXXXXX")"
  sed '/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}BACKUP_DIR=/d' \
    "$MD_JOIN_ENV" > "$tmp_join_env"
  printf 'BACKUP_DIR=%s\n' "$migrated_dir" >> "$tmp_join_env"
  chmod 600 "$tmp_join_env"
  chown root:root "$tmp_join_env" 2>/dev/null || true
  mv -f "$tmp_join_env" "$MD_JOIN_ENV"

  log "Legacy pre-join backup migrated: ${legacy_manifest} -> ${migrated_dir}"
  return 0
}

load_prejoin_backup() {
  local backup
  backup="$(join_state_value BACKUP_DIR 2>/dev/null || true)"
  if [[ -z "$backup" ]]; then
    migrate_legacy_prejoin_backup || return 1
    return 0
  fi
  case "$backup" in "$MD_BACKUPS_ROOT"/join-*) ;; *) return 1 ;; esac
  [[ -d "$backup" && -r "$backup/manifest.env" ]] || return 1
  MD_BACKUP_DIR="$backup"
  MD_MANIFEST="$backup/manifest.env"
}

load_active_backup() {
  local backup
  if [[ -r "$MD_PENDING_BACKUP" ]]; then
    IFS= read -r backup < "$MD_PENDING_BACKUP"
    case "$backup" in "$MD_BACKUPS_ROOT"/join-*|"$MD_BACKUPS_ROOT"/rejoin-*) ;; *) return 1 ;; esac
    [[ -d "$backup" && -r "$backup/manifest.env" ]] || return 1
    MD_BACKUP_DIR="$backup"
    MD_MANIFEST="$backup/manifest.env"
    case "$backup" in
      "$MD_BACKUPS_ROOT"/rejoin-*)
        MD_OPERATION_NM_DNS_STATE="${backup}/networkmanager-dns.env"
        ;;
      *)
        MD_OPERATION_NM_DNS_STATE=""
        ;;
    esac
    return 0
  fi
  MD_OPERATION_NM_DNS_STATE=""
  load_prejoin_backup
}

md_init_state() {
  mkdir -p "${MD_STATE_DIR}"
  # A new transaction must not inherit an orphaned marker from an already
  # completed rollback.
  rm -f "${MD_ROLLBACK_MARKER}"
  chmod 700 "${MD_STATE_DIR}"
}

md_track() {
  local path="$1"

  [[ -n "$path" ]] || return 0

  : # The centralized manifest is complete before the first modification.
}

md_is_tracked() {
  local path="$1"

  local key
  key="$(backup_key "$path")"
  [[ -f "${MD_MANIFEST:-}" ]] && grep -q "^${key}_PATH=" "$MD_MANIFEST"
}

md_backup_once() {
  local path="$1"
  local key rel existed=0

  md_is_tracked "$path" && return 0
  [[ -n "${MD_BACKUP_DIR:-}" && -f "${MD_MANIFEST:-}" ]] \
    || die "No backup transaction is loaded for ${path}; check BACKUP_DIR in ${MD_JOIN_ENV}"
  key="$(backup_key "$path")"
  rel="${path#/}"
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$MD_BACKUP_DIR/files/$(dirname "$rel")"
    cp -a -- "$path" "$MD_BACKUP_DIR/files/$rel" || die "Failed to back up: $path"
    existed=1
  fi
  printf '%s_PATH=%q\n%s_EXISTED=%s\n%s_BACKUP=%q\n' \
    "$key" "$path" "$key" "$existed" "$key" "files/$rel" >> "$MD_MANIFEST"
  log "Dynamically registered backup target: $path"
}

md_backup_exists() {
  local path="$1"
  local key
  key="$(backup_key "$path")"
  grep -q "^${key}_EXISTED=1$" "${MD_MANIFEST:-/nonexistent}" 2>/dev/null
}

restore_one() {
  local path="$1"
  local key rel existed
  key="$(backup_key "$path")"
  existed="$(sed -n "s/^${key}_EXISTED=//p" "$MD_MANIFEST" | tail -n1)"
  rel="${path#/}"
  if [[ "$existed" == 1 ]]; then
    [[ -e "${MD_BACKUP_DIR}/files/${rel}" || -L "${MD_BACKUP_DIR}/files/${rel}" ]] || return 1
    rm -rf "$path"
    mkdir -p "$(dirname -- "$path")"
    cp -a -- "${MD_BACKUP_DIR}/files/${rel}" "$path"
    log "Restored: $path"
  elif [[ "$existed" == 0 ]]; then
    rm -rf -- "$path"
    log "Removed join-created path: $path"
  else
    return 1
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
