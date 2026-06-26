#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"

KRB5_SRC="${FILES_DIR}/krb5.conf"
NSSWITCH_SRC="${FILES_DIR}/nsswitch.conf"
SSH_MD_SRC="${FILES_DIR}/ssh_md.conf"
SSSD_CONF_D_SRC="${FILES_DIR}/sssd.conf.d"
PAM_D_SRC="${FILES_DIR}/pam.d"
SUDOERS_D_SRC="${FILES_DIR}/sudoers.d"
RESOLVED_CONF_D_SRC="${FILES_DIR}/resolved.conf.d"
SALT_SRC="${FILES_DIR}/salt"
SALT_MODULES_SRC="${FILES_DIR}/_modules"
SALT_MINION_EXTMODS_MODULES_DIR="/var/cache/salt/minion/extmods/modules"
SALT_PKG_MODULE_SRC="${SALT_MODULES_SRC}/pkg.py"
SALT_PKG_MODULE_DST="${SALT_MINION_EXTMODS_MODULES_DIR}/pkg.py"

MD_ETC_DIR="/etc/MultiDirectory"
MD_STATE_DIR="${MD_ETC_DIR}/state"
MD_BACKUP_DIR="${MD_STATE_DIR}/backups"
MD_MANIFEST="${MD_STATE_DIR}/manifest"
MD_JOIN_ENV="${MD_STATE_DIR}/join.env"
MD_ROLLBACK_MARKER="${MD_STATE_DIR}/rollback-in-progress"

INSTALL_STATE_DIR="/var/lib/MultiDirectory/install"
INSTALL_ENV="${INSTALL_STATE_DIR}/install.env"

LOG_FILE="/var/log/multidirectory-join.log"
API_CONNECT_TIMEOUT=10
API_MAX_TIME=30

log_raw() {
  local msg="$1"

  printf '%b\n' "$msg" > /dev/tty
  printf '%b\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
  log_raw "${GREEN}[OK]${NC} $*"
}

warn() {
  log_raw "${YELLOW}[WARN]${NC} $*"
}

die() {
  log_raw "${RED}[ERR]${NC} $*"
  exit 1
}

tty_echo() {
  log_raw "$*"
}

usage() {
  echo "Usage: $0 {join|leave}" > /dev/tty
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo $0 {join|leave}"
  fi
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  log "Log file: ${LOG_FILE}"
  log "Script directory: ${SCRIPT_DIR}"
  log "Files directory: ${FILES_DIR}"
  log "State directory: ${MD_STATE_DIR}"
  log "Install state file: ${INSTALL_ENV}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_file() {
  [[ -f "$1" ]] || die "File not found: $1"
  [[ -s "$1" ]] || die "File is empty: $1"
}

need_dir() {
  [[ -d "$1" ]] || die "Directory not found: $1"
}

read_tty() {
  local var="$1"
  local prompt="$2"

  printf '%b ' "${YELLOW}${prompt}${NC}" > /dev/tty
  IFS= read -r "$var" < /dev/tty

  printf '[INPUT] %s %s\n' "$prompt" "${!var}" >> "$LOG_FILE" 2>/dev/null || true
}

read_secret_tty() {
  local var="$1"
  local prompt="$2"

  printf '%b ' "${YELLOW}${prompt}${NC}" > /dev/tty
  IFS= read -rs "$var" < /dev/tty
  printf '\n' > /dev/tty

  printf '[INPUT] %s ********\n' "$prompt" >> "$LOG_FILE" 2>/dev/null || true
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-${OS_ID}}"
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
    die "salt-minion command not found. Run install_packages.sh join and check local Salt package."
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

  need_dir "$src_dir"
  mkdir -p "$dst_dir"

  shopt -s nullglob
  local files=("${src_dir}"/*)
  shopt -u nullglob

  for src in "${files[@]}"; do
    [[ -f "$src" ]] || continue
    install_local_file "$src" "${dst_dir}/$(basename "$src")" "$mode"
  done
}

validate_non_empty_conf_dir() {
  local dir="$1"

  need_dir "$dir"

  shopt -s nullglob
  local files=("${dir}"/*.conf)
  shopt -u nullglob

  (( ${#files[@]} > 0 )) || die "No .conf files found in ${dir}"
}

validate_files_structure() {
  need_dir "$FILES_DIR"
  need_file "$KRB5_SRC"
  need_file "$NSSWITCH_SRC"
  need_file "$SSH_MD_SRC"
  need_dir "$SSSD_CONF_D_SRC"
  validate_non_empty_conf_dir "$SSSD_CONF_D_SRC"
  need_dir "$PAM_D_SRC"

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    need_dir "$SALT_SRC"

    if [[ -f "$SALT_PKG_MODULE_SRC" ]]; then
      need_file "$SALT_PKG_MODULE_SRC"
    else
      warn "Custom Salt module not found, pkg.py install will be skipped: ${SALT_PKG_MODULE_SRC}"
    fi
  fi
}

apply_placeholders_to_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  sed -i \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s/__REALM__/${REALM}/g" \
    -e "s/__KDC__/${KDC}/g" \
    -e "s/__KADMIN__/${KADMIN}/g" \
    -e "s#__URI__#${URI}#g" \
    -e "s#__LDAP_SEARCH_BASE__#${LDAP_SEARCH_BASE}#g" \
    -e "s#__LDAP_USER_BASE__#${LDAP_USER_BASE}#g" \
    -e "s#__LDAP_GROUP_BASE__#${LDAP_GROUP_BASE}#g" \
    -e "s/__HOSTNAME__/${HOSTNAME}/g" \
    -e "s/__FQDN__/${FQDN}/g" \
    -e "s#__LDAP_COMPUTER_OU__#${LDAP_COMPUTER_OU}#g" \
    -e "s/__SALT_MASTER__/${SALT_MASTER:-}/g" \
    "$file"
}

apply_placeholders_in_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' file_path; do
    [[ -f "$file_path" ]] || continue
    apply_placeholders_to_file "$file_path"
  done < <(find "$dir" -type f -print0)
}

valid_hostname() {
  local h="$1"
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

apply_hostname() {
  local new_short="$1"

  HOSTNAME="$new_short"
  FQDN="${HOSTNAME}.${DOMAIN}"

  log "Renaming host: ${HOSTNAME} (${FQDN})"

  md_backup_once /etc/hostname
  md_backup_once /etc/hosts

  if have_cmd hostnamectl; then
    hostnamectl set-hostname "$FQDN"
  else
    echo "$FQDN" > /etc/hostname
    hostname "$FQDN" || true
  fi

  if [[ -f /etc/hosts ]]; then
    if grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
      sed -i -E "s/^\s*127\.0\.1\.1\s+.*/127.0.1.1\t${FQDN} ${HOSTNAME}/" /etc/hosts
    else
      echo -e "127.0.1.1\t${FQDN} ${HOSTNAME}" >> /etc/hosts
    fi
  fi

  md_track /etc/hostname
  md_track /etc/hosts
}

prompt_change_hostname() {
  local current choice new_name

  current="$(hostname -s | tr '[:upper:]' '[:lower:]')"

  tty_echo "${YELLOW}Change PC name?${NC}"
  tty_echo "1. No (${current})"
  tty_echo "2. Yes"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"

    case "$choice" in
      1)
        HOSTNAME="$current"
        FQDN="${HOSTNAME}.${DOMAIN}"
        return 0
        ;;
      2)
        while true; do
          read_tty new_name "Enter new PC name:"
          new_name="$(echo "$new_name" | tr '[:upper:]' '[:lower:]')"

          if valid_hostname "$new_name"; then
            apply_hostname "$new_name"
            return 0
          fi

          warn "Invalid hostname. Use lowercase letters, digits and hyphen."
        done
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

prompt_edition() {
  local choice

  tty_echo "${YELLOW}Select MultiDirectory edition:${NC}"
  tty_echo "1. Enterprise"
  tty_echo "2. Community"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"

    case "$choice" in
      1)
        EDITION="enterprise"
        WITH_SALT=1
        log "Selected edition: Enterprise"
        return 0
        ;;
      2)
        EDITION="community"
        WITH_SALT=0
        log "Selected edition: Community"
        return 0
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

load_or_prompt_edition() {
  if [[ -f "$INSTALL_ENV" ]]; then
    # shellcheck disable=SC1090
    . "$INSTALL_ENV"

    if [[ "${EDITION:-}" == "enterprise" && "${WITH_SALT:-}" == "1" ]]; then
      log "Using edition from install state: Enterprise"
      return 0
    fi

    if [[ "${EDITION:-}" == "community" && "${WITH_SALT:-}" == "0" ]]; then
      log "Using edition from install state: Community"
      return 0
    fi

    warn "Invalid edition state in ${INSTALL_ENV}, asking again"
  else
    warn "Install state file not found: ${INSTALL_ENV}, asking edition manually"
  fi

  prompt_edition
}

detect_default_iface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

configure_dns_systemd_resolved() {
  local ns="$1"
  local resolved_dir="/etc/systemd/resolved.conf.d"
  local resolved_file="${resolved_dir}/MultiDirectory.conf"
  local resolv_target=""

  have_cmd systemctl || return 1
  systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1 || return 1

  mkdir -p "$resolved_dir"
  md_backup_once "$resolved_file"

  cat > "$resolved_file" <<EOF
[Resolve]
DNS=${ns}
EOF

  chmod 0644 "$resolved_file"
  md_track "$resolved_file"

  systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
  systemctl restart systemd-resolved.service || true

  if [[ -e /run/systemd/resolve/resolv.conf ]]; then
    resolv_target="/run/systemd/resolve/resolv.conf"
  elif [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    resolv_target="/run/systemd/resolve/stub-resolv.conf"
  fi

  if [[ -n "$resolv_target" ]]; then
    md_backup_once /etc/resolv.conf
    rm -f /etc/resolv.conf
    ln -s "$resolv_target" /etc/resolv.conf
    md_track /etc/resolv.conf
    log "resolv.conf linked to ${resolv_target}"
  else
    warn "systemd-resolved resolv.conf target not found; /etc/resolv.conf symlink was not changed"
  fi

  log "Persistent DNS configured via systemd-resolved: ${ns}"
  return 0
}

configure_dns_networkmanager() {
  local ns="$1"
  local iface conn

  have_cmd nmcli || return 1
  systemctl is-active --quiet NetworkManager.service 2>/dev/null || return 1

  iface="$(detect_default_iface)"
  [[ -n "$iface" ]] || return 1

  conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')"
  [[ -n "$conn" ]] || return 1

  nmcli connection modify "$conn"     ipv4.dns "$ns"     ipv4.ignore-auto-dns yes || return 1

  nmcli connection up "$conn" >/dev/null 2>&1 || true

  log "Persistent DNS configured via NetworkManager connection '${conn}': ${ns}"
  return 0
}

configure_dns_static_resolv_conf() {
  local ns="$1"
  local tmp

  md_backup_once /etc/resolv.conf

  if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
  fi

  tmp="$(mktemp)"
  echo "nameserver ${ns}" > "$tmp"

  if [[ -f /etc/resolv.conf ]]; then
    grep -vE "^nameserver[[:space:]]+${ns}([[:space:]]|$)" /etc/resolv.conf >> "$tmp" 2>/dev/null || true
  fi

  cp "$tmp" /etc/resolv.conf
  rm -f "$tmp"

  chmod 0644 /etc/resolv.conf
  md_track /etc/resolv.conf

  log "Persistent DNS configured via static /etc/resolv.conf: ${ns}"
}

md_set_resolv_first() {
  local ns="$1"

  if configure_dns_systemd_resolved "$ns"; then
    return 0
  fi

  if configure_dns_networkmanager "$ns"; then
    return 0
  fi

  configure_dns_static_resolv_conf "$ns"
}

prompt_configure_dns() {
  local choice dns_ip
  tty_echo "${YELLOW}Set MultiDirectory DNS server?${NC}"
  tty_echo "1. Yes"
  tty_echo "2. No"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"
    case "$choice" in
      1)
        while true; do
          read_tty dns_ip "Enter DNS server IP:"
          if [[ -n "${dns_ip}" && ! "$dns_ip" =~ [[:space:]] ]]; then
            MD_DNS_SERVER="$dns_ip"
            if md_set_resolv_first "$dns_ip"; then
              return 0
            else
              warn "Failed to set DNS. Please check the IP address and network."
            fi
          else
            warn "Invalid DNS server address."
          fi
        done
        ;;
      2) log "DNS configuration skipped"; return 0 ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
}

api_auth_cookie() {
  local user="$1"
  local pass="$2"

  curl -k -sS -X POST "https://${API_HOST}/api/auth/" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}" \
    -D - -o /dev/null \
    | awk -F'id=|;' 'BEGIN{IGNORECASE=1} /set-cookie:[[:space:]]*id=/{print $2; exit}' \
    | tr -d '\r\n'
}

api_search() {
  local cookie="$1"
  local base_object="$2"
  local scope="$3"
  local filter="$4"
  local attrs_json="$5"

  curl -k -sS -X POST "https://${API_HOST}/api/entry/search" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Cookie: id=${cookie}" \
    -H "Content-Type: application/json" \
    -d "{
      \"base_object\": \"${base_object}\",
      \"scope\": ${scope},
      \"deref_aliases\": 0,
      \"size_limit\": 5,
      \"time_limit\": 0,
      \"types_only\": false,
      \"filter\": \"${filter}\",
      \"attributes\": ${attrs_json}
    }"
}

api_rootdse_default_nc() {
  local cookie="$1"
  local resp

  resp="$(api_search "$cookie" "" 0 "(objectClass=*)" "[\"defaultNamingContext\"]")"

  printf '%s' "$resp" | jq -r '
    (.search_result[0].partial_attributes[]? | select(.type=="defaultNamingContext") | .vals[0]) // empty
  '
}

dn_to_domain() {
  awk -F',' '
    {
      out="";
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i);
        if ($i ~ /^dc=/ || $i ~ /^DC=/) {
          sub(/^[dD][cC]=/, "", $i);
          out = (out == "" ? $i : out "." $i);
        }
      }
      print tolower(out);
    }
  '
}

api_rootdse_domain() {
  local cookie="$1"
  local resp dom nc

  resp="$(api_search "$cookie" "" 0 "(objectClass=*)" "[\"dnsDomainName\",\"dnsForestName\",\"dnsHostName\",\"defaultNamingContext\"]")"

  dom="$(printf '%s' "$resp" | jq -r '
    (.search_result[0].partial_attributes[]? | select(.type=="dnsDomainName") | .vals[0]) // empty
  ')"

  [[ -n "$dom" ]] || dom="$(printf '%s' "$resp" | jq -r '
    (.search_result[0].partial_attributes[]? | select(.type=="dnsForestName") | .vals[0]) // empty
  ')"

  if [[ -z "$dom" ]]; then
    nc="$(printf '%s' "$resp" | jq -r '
      (.search_result[0].partial_attributes[]? | select(.type=="defaultNamingContext") | .vals[0]) // empty
    ')"
    [[ -n "$nc" ]] && dom="$(printf '%s' "$nc" | dn_to_domain)"
  fi

  printf '%s' "$dom"
}

api_principal_add() {
  local cookie="$1"
  local spn="$2"
  local primary="${spn%%/*}"
  local instance="${spn#*/}"

  curl -k -sS -X POST "https://${API_HOST}/api/kerberos/principal/add" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Cookie: id=${cookie}" \
    -d "{\"primary\":\"${primary}\",\"instance\":\"${instance}\"}" \
    -o /tmp/md-principal-add.body \
    -w '%{http_code}' 2>/dev/null
}

response_content_type() {
  local headers="$1"

  awk -F': *' '
    BEGIN { IGNORECASE=1 }
    /^content-type:/ {
      gsub(/\r$/, "", $2)
      value=$2
    }
    END { print value }
  ' "$headers" 2>/dev/null || true
}

api_ktadd_download() {
  local cookie="$1"
  shift
  local spn body sep http_code content_type detail

  rm -f /tmp/md-ktadd.hdr /tmp/md-ktadd.body /etc/krb5.keytab

  if [[ "${EDITION}" == "community" ]]; then
    log "Community: registering principals"
    body="["
    sep=""
    for spn in "$@"; do
      log "${spn}: HTTP $(api_principal_add "${cookie}" "${spn}")"
      body="${body}${sep}\"${spn}@${REALM}\""
      sep=","
    done
    body="${body}]"
  else
    body="{\"names\":["
    sep=""
    for spn in "$@"; do
      body="${body}${sep}\"${spn}\""
      sep=","
    done
    body="${body}],\"is_rand_key\":true}"
  fi

  log "Keytab API endpoint: https://${API_HOST}/api/kerberos/ktadd"
  log "Keytab principals: $*"

  http_code="$(
    curl -k -sS \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -D /tmp/md-ktadd.hdr \
      -o /tmp/md-ktadd.body \
      -X POST "https://${API_HOST}/api/kerberos/ktadd" \
      -H "accept: application/octet-stream" \
      -H "Content-Type: application/json" \
      -H "Cookie: id=${cookie}" \
      -d "${body}" \
      -w '%{http_code}' 2>/dev/null
  )" || http_code="000"

  content_type="$(response_content_type /tmp/md-ktadd.hdr)"
  log "Keytab API response: HTTP ${http_code}, content-type=${content_type:-unknown}"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(
      jq -r '
        if type == "object" then
          (.detail // .message // .error // tostring)
        else
          tostring
        end
      ' /tmp/md-ktadd.body 2>/dev/null || head -n 20 /tmp/md-ktadd.body 2>/dev/null || true
    )"

    die "Keytab retrieval failed. HTTP ${http_code}: ${detail}"
  fi

  if printf '%s' "$content_type" | grep -Eiq 'json|text|html'; then
    warn "API returned non-binary keytab:"
    head -n 60 /tmp/md-ktadd.body || true
    die "keytab was not received as a binary file"
  fi

  if [[ ! -s /tmp/md-ktadd.body ]]; then
    die "keytab was not received: empty API response body"
  fi

  if file /tmp/md-ktadd.body 2>/dev/null | grep -Ei 'json|text|html' >/dev/null; then
    warn "API returned non-binary keytab:"
    head -n 60 /tmp/md-ktadd.body || true
    die "keytab was not received as a binary file"
  fi

  install -m 600 -o root -g root /tmp/md-ktadd.body /etc/krb5.keytab
  md_track /etc/krb5.keytab

  log "Keytab installed: /etc/krb5.keytab"
}

api_update_many_replace_uac() {
  local cookie="$1"
  local object_dn="$2"
  local uac_value="$3"
  local payload resp http_code body

  payload="$(jq -n \
    --arg object "$object_dn" \
    --arg uac "$uac_value" \
    '[
      {
        object: $object,
        changes: [
          {
            operation: 2,
            modification: {
              type: "userAccountControl",
              vals: [$uac]
            }
          }
        ]
      }
    ]'
  )"

  resp="$(
    curl -k -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X PATCH "https://${API_HOST}/api/entry/update_many" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Cookie: id=${cookie}" \
      -d "${payload}" 2>&1
  )" || true

  http_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi

  warn "Failed to update userAccountControl for ${object_dn}. HTTP ${http_code}: ${body}"
  return 1
}

api_find_computer_object_dn() {
  local cookie="$1"
  local computer_ou="$2"
  local computer_name="$3"
  local resp dn

  resp="$(
    api_search "$cookie" "$computer_ou" 2 "(&(objectClass=computer)(cn=${computer_name}))" "[\"cn\",\"userAccountControl\"]" 2>&1
  )" || {
    return 2
  }

  dn="$(printf '%s' "$resp" | jq -r '.search_result[0].object_name // empty' 2>/dev/null || true)"
  [[ -n "$dn" ]] || return 1

  printf '%s' "$dn"
  return 0
}

enable_computer_account() {
  local object_dn="$1"

  api_update_many_replace_uac "${access_token}" "${object_dn}" "4096" \
    || die "Failed to enable computer account: ${object_dn}"

}

disable_computer_account_on_leave() {
  local object_dn expected_dn lookup_rc

  [[ -n "${HOSTNAME:-}" ]] || {
    warn "HOSTNAME is unknown, computer account disable skipped"
    return 0
  }

  [[ -n "${LDAP_COMPUTER_OU:-}" ]] || {
    warn "LDAP_COMPUTER_OU is unknown, computer account disable skipped"
    return 0
  }

  [[ -n "${access_token:-}" ]] || {
    warn "API access token is missing, computer account disable skipped"
    return 0
  }

  expected_dn="cn=${HOSTNAME},${LDAP_COMPUTER_OU}"

  if object_dn="$(api_find_computer_object_dn "${access_token}" "${LDAP_COMPUTER_OU}" "${HOSTNAME}")"; then
    lookup_rc=0
  else
    lookup_rc=$?
  fi

  case "$lookup_rc" in
    0)
      ;;
    1)
      warn "Computer object not found in LDAP: ${expected_dn}"
      warn "Skipping remote computer disable"
      return 0
      ;;
    2)
      warn "Timeout while checking computer object, skipping remote disable"
      return 0
      ;;
    *)
      warn "Failed to check computer object, skipping remote disable: ${expected_dn}"
      return 0
      ;;
  esac

  warn "Disabling computer account: ${object_dn}"
  if api_update_many_replace_uac "${access_token}" "${object_dn}" "4098"; then
    log "Computer account disabled: ${object_dn}"
  else
    warn "Computer account was not disabled on server side; local leave will continue"
  fi
}

validate_api_host_resolution() {
  log "Checking DNS resolution: ${API_HOST}"
  getent hosts "${API_HOST}" >/dev/null || die "DNS resolution failed: ${API_HOST}"
  log "DNS resolution OK: ${API_HOST}"
}

validate_salt_host_resolution() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || {
    log "Community edition: salt DNS check skipped"
    return 0
  }

  [[ -n "${SALT_MASTER:-}" ]] || {
    log "Salt master is not known yet, salt DNS check skipped"
    return 0
  }

  log "Checking DNS resolution: ${SALT_MASTER}"
  getent hosts "${SALT_MASTER}" >/dev/null || die "DNS resolution failed: ${SALT_MASTER}"
  log "DNS resolution OK: ${SALT_MASTER}"
}

validate_initial_hosts_resolution() {
  validate_api_host_resolution

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    SALT_MASTER="salt.${API_HOST}"
    validate_salt_host_resolution
  fi
}

validate_admin_credentials() {
  log "Authenticating domain administrator via API"

  access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"
  [[ -n "${access_token}" ]] || die "Failed to authenticate domain administrator"

  log "Domain administrator credentials are valid"
}

discover_and_validate_domain() {
  log "Detecting domain via RootDSE"

  DOMAIN="$(api_rootdse_domain "${access_token}")"
  [[ -n "${DOMAIN}" ]] || die "Failed to detect DOMAIN via RootDSE"
  DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

  log "Detected domain: ${DOMAIN}"

  log "Getting defaultNamingContext"

  LDAP_BASE_DN="$(api_rootdse_default_nc "${access_token}")"
  [[ -n "${LDAP_BASE_DN}" ]] || die "Failed to get defaultNamingContext"

  log "Detected defaultNamingContext: ${LDAP_BASE_DN}"

  REALM="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"
  KDC="$DOMAIN"
  KADMIN="$DOMAIN"
  URI="ldap://${DOMAIN}"
  LDAP_SEARCH_BASE="$LDAP_BASE_DN"
  LDAP_USER_BASE="$LDAP_BASE_DN"
  LDAP_GROUP_BASE="$LDAP_BASE_DN"
  LDAP_COMPUTER_OU="cn=computers,${LDAP_BASE_DN}"

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    SALT_MASTER="salt.${DOMAIN}"
  fi
}

validate_sudoers() {
  if have_cmd visudo; then
    visudo -cf /etc/sudoers || die "sudoers validation failed"
  else
    warn "visudo not found, sudoers validation skipped"
  fi
}

validate_sssd_config() {
  if have_cmd sssctl; then
    sssctl config-check || die "SSSD configuration is invalid"
  else
    warn "sssctl not found, SSSD config validation skipped"
  fi
}

validate_no_password_based_sssd_auth() {
  local forbidden='ldap_default_bind_dn|ldap_default_authtok|ldap_default_authtok_type|__SSSD_|__BIND_DN__|__PASSWORD__'

  [[ -f /etc/sssd/sssd.conf ]] || return 0

  if grep -En "$forbidden" /etc/sssd/sssd.conf >/tmp/md-sssd-password-auth.matches 2>/dev/null; then
    warn "Forbidden password-based SSSD settings found:"
    cat /tmp/md-sssd-password-auth.matches || true
    die "SSSD must use Kerberos GSSAPI with /etc/krb5.keytab only"
  fi
}

disable_sssd_socket_activation_if_needed() {
  local services_line unit disabled_count=0
  local sockets=(
    sssd-nss.socket
    sssd-pam.socket
    sssd-pam-priv.socket
    sssd-ssh.socket
    sssd-sudo.socket
  )

  [[ -f /etc/sssd/sssd.conf ]] || return 0
  have_cmd systemctl || return 0

  services_line="$(
    awk '
      BEGIN { in_sssd=0 }
      /^\[sssd\]/ { in_sssd=1; next }
      /^\[/ { in_sssd=0 }
      in_sssd && /^[[:space:]]*services[[:space:]]*=/ { print; exit }
    ' /etc/sssd/sssd.conf 2>/dev/null || true
  )"

  [[ -n "$services_line" ]] || {
    log "SSSD services line not found, socket activation will not be changed"
    return 0
  }

  if ! echo "$services_line" | grep -Eq '(^|[,=[:space:]])(nss|pam|ssh|sudo)([,[:space:]]|$)'; then
    log "SSSD services line does not contain nss/pam/ssh/sudo, socket activation will not be changed"
    return 0
  fi

  log "SSSD services are configured in /etc/sssd/sssd.conf; disabling conflicting socket activation units if present"

  systemctl daemon-reload >/dev/null 2>&1 || true

  for unit in "${sockets[@]}"; do
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^${unit}"; then
      systemctl stop "$unit" 2>/dev/null || true
      systemctl disable "$unit" 2>/dev/null || true
      systemctl mask "$unit" 2>/dev/null || true
      disabled_count=$((disabled_count + 1))
    fi
  done

  if [[ "$disabled_count" -gt 0 ]]; then
    log "Disabled and masked conflicting SSSD socket activation units: ${disabled_count}"
  fi
}

build_sssd_conf() {
  need_dir "$SSSD_CONF_D_SRC"
  validate_non_empty_conf_dir "$SSSD_CONF_D_SRC"

  mkdir -p /etc/sssd
  chmod 700 /etc/sssd

  md_backup_once /etc/sssd/sssd.conf

  if [[ -d /etc/sssd/conf.d ]]; then
    md_backup_once /etc/sssd/conf.d
    rm -rf /etc/sssd/conf.d
    log "Removed old SSSD snippets from /etc/sssd/conf.d"
  fi

  mkdir -p /etc/sssd/conf.d
  chown root:root /etc/sssd/conf.d
  chmod 700 /etc/sssd/conf.d

  : > /etc/sssd/sssd.conf

  shopt -s nullglob
  local files=("${SSSD_CONF_D_SRC}"/*.conf)
  shopt -u nullglob

  local src
  for src in "${files[@]}"; do
    echo "# Source template: $(basename "$src")" >> /etc/sssd/sssd.conf
    cat "$src" >> /etc/sssd/sssd.conf
    echo >> /etc/sssd/sssd.conf
  done

  apply_placeholders_to_file /etc/sssd/sssd.conf

  chown root:root /etc/sssd/sssd.conf
  chmod 600 /etc/sssd/sssd.conf
  chmod 700 /etc/sssd

  md_track /etc/sssd/sssd.conf

  disable_sssd_socket_activation_if_needed

  log "Built single SSSD config: /etc/sssd/sssd.conf"
  log "SSSD conf.d kept empty: /etc/sssd/conf.d"
}

install_pam_config() {
  if is_redos_or_rhel_like; then
    if have_cmd authselect; then
      authselect select sssd with-mkhomedir --force || true
    fi

    systemctl enable --now oddjobd.service 2>/dev/null || true
    return 0
  fi

  if is_altlinux; then
    need_dir "$PAM_D_SRC"

    [[ -f "${PAM_D_SRC}/alt-system-auth" ]] && install_local_file "${PAM_D_SRC}/alt-system-auth" /etc/pam.d/system-auth 0644
    [[ -f "${PAM_D_SRC}/alt-su" ]] && install_local_file "${PAM_D_SRC}/alt-su" /etc/pam.d/su 0644
    [[ -f "${PAM_D_SRC}/alt-sshd" ]] && install_local_file "${PAM_D_SRC}/alt-sshd" /etc/pam.d/sshd 0644
    [[ -f "${PAM_D_SRC}/alt-gdm-password" && -f /etc/pam.d/gdm-password ]] && install_local_file "${PAM_D_SRC}/alt-gdm-password" /etc/pam.d/gdm-password 0644
    [[ -f "${PAM_D_SRC}/alt-login" && -f /etc/pam.d/login ]] && install_local_file "${PAM_D_SRC}/alt-login" /etc/pam.d/login 0644
    [[ -f "${PAM_D_SRC}/alt-common-login" && -f /etc/pam.d/common-login ]] && install_local_file "${PAM_D_SRC}/alt-common-login" /etc/pam.d/common-login 0644

    chmod 4711 /usr/bin/sudo 2>/dev/null || true
    return 0
  fi

  if is_deb_based; then
    if [[ -d "$PAM_D_SRC" ]]; then
      [[ -f "${PAM_D_SRC}/common-auth" ]] && install_local_file "${PAM_D_SRC}/common-auth" /etc/pam.d/common-auth 0644
      [[ -f "${PAM_D_SRC}/common-account" ]] && install_local_file "${PAM_D_SRC}/common-account" /etc/pam.d/common-account 0644
      [[ -f "${PAM_D_SRC}/common-session" ]] && install_local_file "${PAM_D_SRC}/common-session" /etc/pam.d/common-session 0644
      [[ -f "${PAM_D_SRC}/common-password" ]] && install_local_file "${PAM_D_SRC}/common-password" /etc/pam.d/common-password 0644
    else
      pam-auth-update --enable mkhomedir || true
    fi
  fi
}

install_static_configs() {
  log "Installing config files from ${FILES_DIR}"

  install_local_file "$KRB5_SRC" /etc/krb5.conf 0644
  apply_placeholders_to_file /etc/krb5.conf

  install_local_file "$NSSWITCH_SRC" /etc/nsswitch.conf 0644

  mkdir -p /etc/ssh/sshd_config.d
  install_local_file "$SSH_MD_SRC" /etc/ssh/sshd_config.d/ssh_md.conf 0644

  build_sssd_conf
  install_pam_config

  if [[ -d "$SUDOERS_D_SRC" ]]; then
    mkdir -p /etc/sudoers.d
    copy_dir_files "$SUDOERS_D_SRC" /etc/sudoers.d 0440
    apply_placeholders_in_dir /etc/sudoers.d
    find /etc/sudoers.d -type f -exec chmod 0440 {} \; 2>/dev/null || true
    validate_sudoers
  fi

  if [[ -d "$RESOLVED_CONF_D_SRC" ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    copy_dir_files "$RESOLVED_CONF_D_SRC" /etc/systemd/resolved.conf.d 0644
    apply_placeholders_in_dir /etc/systemd/resolved.conf.d
  fi

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    if [[ -d "$SALT_SRC" ]]; then
      mkdir -p /etc/salt
      copy_dir_files "$SALT_SRC" /etc/salt 0644
      apply_placeholders_in_dir /etc/salt
    fi

    install_salt_custom_modules
  else
    log "Community edition: Salt config files are skipped"
  fi
}

create_computer_object_if_needed() {
  local computer_dn exists_dn add_resp add_http add_body

  computer_dn="cn=${HOSTNAME},${LDAP_COMPUTER_OU}"

  log "Checking whether computer cn=${HOSTNAME} exists"

  exists_dn="$(
    api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=computer)(cn=${HOSTNAME}))" "[\"cn\",\"userAccountControl\"]" \
      | jq -r '.search_result[0].object_name // empty'
  )"

  if [[ -n "${exists_dn}" ]]; then
    warn "Computer already exists in LDAP: ${exists_dn}. Creating will be skipped."
    enable_computer_account "${exists_dn}"
    return 0
  fi

  log "Creating computer object: ${computer_dn}"

  add_resp="$(
    curl -k -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X POST "https://${API_HOST}/api/entry/add" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Cookie: id=${access_token}" \
      -d "{
        \"entry\": \"${computer_dn}\",
        \"attributes\": [
          { \"type\": \"objectClass\", \"vals\": [\"top\", \"computer\"] },
          { \"type\": \"description\", \"vals\": [\"\"] }
        ]
      }" 2>&1
  )" || true

  add_http="$(echo "$add_resp" | tail -n1)"
  add_body="$(echo "$add_resp" | sed '$d')"

  if [[ ! "$add_http" =~ ^2[0-9][0-9]$ ]]; then
    die "Failed to create computer object ${computer_dn}. HTTP ${add_http}: ${add_body}"
  fi

  log "Computer object created: ${computer_dn}"
  enable_computer_account "${computer_dn}"
}

validate_keytab() {
  log "Checking keytab"

  klist -k /etc/krb5.keytab || die "Invalid keytab"

  if kinit -k "host/${FQDN}@${REALM}"; then
    log "Kerberos authentication succeeded: host/${FQDN}@${REALM}"
    kdestroy || true
    return 0
  fi

  if kinit -k "host/${HOSTNAME}@${REALM}"; then
    log "Kerberos authentication succeeded: host/${HOSTNAME}@${REALM}"
    kdestroy || true
    return 0
  fi

  die "Kerberos keytab authentication failed"
}

ldap_uri_host() {
  local uri="$1"
  local host

  host="${uri#ldap://}"
  host="${host#ldaps://}"
  host="${host%%/*}"
  if [[ "$host" == \[*\] ]]; then
    host="${host#[}"
    host="${host%%]*}"
  else
    host="${host%%:*}"
  fi

  printf '%s' "$host"
}

validate_ldap_uri_uses_fqdn() {
  local host

  host="$(ldap_uri_host "${URI}")"

  [[ -n "$host" ]] || die "LDAP URI is invalid: ${URI}"

  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$host" == *":"* ]]; then
    die "LDAP URI must use FQDN, not IP address: ${URI}. IP-based Kerberos SPNs such as ldap/${host}@${REALM} are not supported."
  fi

  if [[ "$host" != "${DOMAIN}" && "$host" != "${FQDN}" ]]; then
    warn "LDAP URI host is ${host}; expected ${DOMAIN} or ${FQDN} to avoid Kerberos SPN mismatch"
  fi
}

validate_ldap_gssapi_auth() {
  log "Checking LDAP GSSAPI authentication"

  validate_ldap_uri_uses_fqdn

  if ! kinit -k "host/${FQDN}@${REALM}"; then
    die "Kerberos GSSAPI initialization failed: host/${FQDN}@${REALM}"
  fi

  ldapwhoami -Y GSSAPI -H "${URI}" >/dev/null \
    || {
      kdestroy || true
      die "LDAP GSSAPI authentication failed"
    }

  log "LDAP GSSAPI authentication succeeded"

  kdestroy || true
}

api_delete_salt_minion_key() {
  local cookie="$1"
  local minion_id="$2"

  [[ -n "$minion_id" ]] || return 0

  curl -k -sS -X DELETE "https://${API_HOST}/api/salt/minion/${minion_id}" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "Cookie: id=${cookie}" \
    -H 'accept: application/json' \
    -o /dev/null || true
}

install_salt_custom_modules() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || return 0

  if [[ ! -f "$SALT_PKG_MODULE_SRC" ]]; then
    warn "Custom Salt pkg module not found, skipping: ${SALT_PKG_MODULE_SRC}"
    return 0
  fi

  require_salt_minion_ready

  log "Installing custom Salt module: ${SALT_PKG_MODULE_DST}"

  mkdir -p "$SALT_MINION_EXTMODS_MODULES_DIR"
  md_backup_once "$SALT_PKG_MODULE_DST"

  install -m 0644 -o root -g root "$SALT_PKG_MODULE_SRC" "$SALT_PKG_MODULE_DST"
  md_track "$SALT_PKG_MODULE_DST"

  if have_cmd salt-call; then
    salt-call --local saltutil.refresh_modules >/dev/null 2>&1 \
      && log "Salt custom modules refreshed" \
      || warn "saltutil.refresh_modules failed; module will be loaded after salt-minion restart"
  else
    warn "salt-call not found, Salt custom modules refresh skipped"
  fi

  log "Custom Salt pkg module installed"
}

prepare_salt_minion_identity() {
  local guid="$1"
  local gpo_token="$2"

  require_salt_minion_ready

  log "Preparing Salt minion identity: ${guid}"

  if pgrep -f "salt-minion" > /dev/null 2>&1; then
    pkill -9 -f "salt-minion" 2>/dev/null || true
    sleep 2
    # Проверяем, что убили
    if pgrep -f "salt-minion" > /dev/null 2>&1; then
      warn "Some salt-minion processes still remain, killing again..."
      pkill -9 -f "salt-minion" 2>/dev/null || true
      sleep 1
    fi
    log "Salt processes stopped"
  fi

  rm -rf /etc/salt/pki/minion 2>/dev/null || true
  rm -f /etc/salt/minion_id 2>/dev/null || true

  mkdir -p /etc/salt

  cat > /etc/salt/minion <<EOF
master: ${SALT_MASTER}
master_finger: ${gpo_token}
EOF

  md_backup_once /etc/salt/minion
  md_track /etc/salt/minion

  if [[ -d /etc/salt/minion.d ]]; then
    find /etc/salt/minion.d -type f -name '*.conf' -exec sed -i '/^\s*master\s*:/d' {} \; 2>/dev/null || true
    find /etc/salt/minion.d -type f -name '*.conf' -exec sed -i '/^\s*master_finger\s*:/d' {} \; 2>/dev/null || true
    find /etc/salt/minion.d -type f -name '*.conf' -exec sed -i '/^\s*id\s*:/d' {} \; 2>/dev/null || true
  fi

  echo "$guid" > /etc/salt/minion_id
  chmod 0644 /etc/salt/minion_id
  md_track /etc/salt/minion_id

  systemctl daemon-reload || true
  systemctl enable salt-minion.service >/dev/null 2>&1 || true

  log "Salt minion identity prepared"
}

restart_salt_minion_and_wait() {
  local wait_seconds="${1:-8}"

  restart_salt_minion_or_die

  log "Waiting ${wait_seconds}s for Salt minion key publication"
  sleep "$wait_seconds"
}

accept_salt_minion_key() {
  local guid="$1"
  local resp http_code body
  local retries=12
  local delay=5
  local attempt=1

  while [[ $attempt -le $retries ]]; do
    log "Attempt ${attempt}/${retries}: accepting Salt minion key"

    resp="$(
      curl -k -sS -w "\n%{http_code}" \
        --connect-timeout "${API_CONNECT_TIMEOUT}" \
        --max-time "${API_MAX_TIME}" \
        -X POST "https://${API_HOST}/api/salt/minion" \
        -H 'accept: application/json' \
        -H "Cookie: id=${access_token}" \
        -H 'Content-Type: application/json' \
        -d "{\"id\": \"${guid}\"}" 2>&1
    )" || true

    http_code="$(echo "$resp" | tail -n1)"
    body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" -eq 200 ]]; then
      log "Salt minion key accepted"
      restart_salt_minion_or_die
      return 0
    fi

    if [[ "$http_code" -eq 400 ]] && echo "$body" | grep -qi "Minion Already Exists"; then
      warn "Minion already exists on master. Deleting old key and publishing a fresh key."

      systemctl stop salt-minion.service 2>/dev/null || true
      rm -rf /etc/salt/pki/minion 2>/dev/null || true
      api_delete_salt_minion_key "${access_token}" "${guid}"

      restart_salt_minion_and_wait 8
      ((attempt++))
      continue
    fi

    if [[ "$http_code" -eq 400 ]] && echo "$body" | grep -qi "Unable to accept minion"; then
      warn "Salt key is not ready on master yet. Waiting before retry."
      sleep "$delay"

      if (( attempt % 3 == 0 )); then
        warn "Restarting salt-minion to force key publication"
        restart_salt_minion_and_wait 8
      fi

      ((attempt++))
      continue
    fi

    warn "Salt API returned HTTP ${http_code}: ${body}"
    sleep "$delay"
    ((attempt++))
  done

  print_salt_diagnostics
  die "Failed to accept Salt minion key"
}

configure_salt() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || {
    log "Community edition: Salt steps skipped"
    return 0
  }

  local gpo_token guid

  SALT_MASTER="salt.${DOMAIN}"

  require_salt_minion_ready

  log "Checking DNS resolution: SALT_MASTER=${SALT_MASTER}"
  getent hosts "${SALT_MASTER}" >/dev/null || die "DNS resolution failed for ${SALT_MASTER}"

  gpo_token="$(
    curl -k -sS -X GET "https://${API_HOST}/api/salt/master/key" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -H "Cookie: id=${access_token}" \
      -H 'accept: application/json' \
      | tr -d '\r\n"'
  )"

  [[ -n "${gpo_token}" ]] || die "Failed to get Salt master_finger"

  log "Getting computer objectGUID"
  guid="$(
    api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=*)(cn=${HOSTNAME}))" "[\"objectGUID\"]" \
      | jq -r '.search_result[0].partial_attributes[]? | select(.type=="objectGUID") | .vals[0] // empty'
  )"

  [[ -n "${guid}" ]] || die "Failed to get objectGUID"

  prepare_salt_minion_identity "$guid" "$gpo_token"

  warn "Deleting possible old Salt key for this minion id before fresh registration"
  api_delete_salt_minion_key "${access_token}" "${guid}"

  restart_salt_minion_and_wait 8
  accept_salt_minion_key "$guid"
}

save_join_env() {
  cat > "${MD_JOIN_ENV}" <<EOF
API_HOST=${API_HOST}
DOMAIN=${DOMAIN}
REALM=${REALM}
HOSTNAME=${HOSTNAME}
FQDN=${FQDN}
LDAP_BASE_DN=${LDAP_BASE_DN}
LDAP_COMPUTER_OU=${LDAP_COMPUTER_OU}
EDITION=${EDITION}
WITH_SALT=${WITH_SALT}
SALT_MASTER=${SALT_MASTER:-}
MD_DNS_SERVER=${MD_DNS_SERVER:-}
EOF

  chmod 600 "${MD_JOIN_ENV}"
  md_track "${MD_JOIN_ENV}"
}

load_join_env() {
  [[ -f "$MD_JOIN_ENV" ]] || die "Join state file not found: ${MD_JOIN_ENV}"

  # shellcheck disable=SC1090
  . "$MD_JOIN_ENV"

  [[ -n "${DOMAIN:-}" ]] || die "DOMAIN is missing in ${MD_JOIN_ENV}"
  [[ -n "${API_HOST:-}" ]] || die "API_HOST is missing in ${MD_JOIN_ENV}"

  SAVED_DOMAIN="$DOMAIN"
  SAVED_API_HOST="$API_HOST"

  SAVED_DOMAIN="$(echo "$SAVED_DOMAIN" | tr '[:upper:]' '[:lower:]')"

  log "Saved domain: ${SAVED_DOMAIN}"
  log "Saved API host: ${SAVED_API_HOST}"
}

validate_leave_credentials() {
  local leave_login leave_password leave_token detected_domain

  load_join_env

  read_tty leave_login "Enter domain administrator login:"
  read_secret_tty leave_password "Enter domain administrator password:"

  [[ -n "$leave_login" && -n "$leave_password" ]] || die "Login and password must be filled"

  API_HOST="$SAVED_API_HOST"

  log "Checking DNS resolution: ${API_HOST}"
  getent hosts "${API_HOST}" >/dev/null || die "DNS resolution failed: ${API_HOST}"

  log "Authenticating domain administrator"
  leave_token="$(api_auth_cookie "$leave_login" "$leave_password")"
  [[ -n "$leave_token" ]] || die "Failed to authenticate domain administrator"

  log "Detecting domain via RootDSE"
  detected_domain="$(api_rootdse_domain "$leave_token")"
  [[ -n "$detected_domain" ]] || die "Failed to detect domain via RootDSE"

  detected_domain="$(echo "$detected_domain" | tr '[:upper:]' '[:lower:]')"

  log "Saved domain: ${SAVED_DOMAIN}"
  log "Authenticated domain: ${detected_domain}"

  if [[ "$detected_domain" != "$SAVED_DOMAIN" ]]; then
    unset leave_password
    die "Domain mismatch. Saved domain is ${SAVED_DOMAIN}, but authenticated domain is ${detected_domain}"
  fi

  access_token="$leave_token"
  LOGIN="$leave_login"

  unset leave_password

  log "Leave credentials validated"
}

start_services() {
  local services=(sssd ssh sshd)

  systemctl daemon-reload || true

  if have_cmd sshd; then
    sshd -t || die "Error in sshd configuration"
  fi

  for svc in "${services[@]}"; do
    systemctl enable "${svc}.service" >/dev/null 2>&1 || true
    systemctl restart "${svc}.service" >/dev/null 2>&1 || true
  done

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    restart_salt_minion_or_die
    services+=(salt-minion)
  fi

  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
      log "ACTIVE: ${svc}"
    else
      warn "NOT ACTIVE: ${svc}"
      systemctl status "${svc}.service" --no-pager -l 2>/dev/null || true
    fi
  done
}

stop_domain_services() {
  systemctl stop sssd.service 2>/dev/null || true
  systemctl stop salt-minion.service 2>/dev/null || true
  systemctl disable salt-minion.service 2>/dev/null || true
}

remove_managed_files() {
  if [[ ! -f "$MD_MANIFEST" ]]; then
    warn "Manifest not found: ${MD_MANIFEST}"
    return 0
  fi

  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" == "/" ]] && continue
    [[ "$p" == "$MD_MANIFEST" ]] && continue

    if [[ -L "$p" || -f "$p" ]]; then
      rm -f "$p"
      log "Removed managed file: $p"
    fi
  done < "$MD_MANIFEST"
}

restore_backups() {
  restore_one /etc/krb5.conf
  restore_one /etc/nsswitch.conf
  restore_one /etc/ssh/sshd_config.d/ssh_md.conf
  restore_one /etc/sssd/sssd.conf
  restore_one /etc/sssd/conf.d
  restore_one /etc/hostname
  restore_one /etc/hosts
  restore_one /etc/resolv.conf

  restore_one /etc/pam.d/system-auth
  restore_one /etc/pam.d/su
  restore_one /etc/pam.d/sshd
  restore_one /etc/pam.d/gdm-password
  restore_one /etc/pam.d/login
  restore_one /etc/pam.d/common-login
  restore_one /etc/pam.d/common-auth
  restore_one /etc/pam.d/common-account
  restore_one /etc/pam.d/common-session
  restore_one /etc/pam.d/common-password

  restore_one /etc/salt/minion
  restore_one /etc/salt/minion_id
  restore_one /etc/salt/pki/minion
  restore_one "$SALT_PKG_MODULE_DST"
}

cleanup_domain_state() {
  rm -f /etc/krb5.keytab

  if [[ -f "${MD_JOIN_ENV}" || -f "${MD_ROLLBACK_MARKER}" ]]; then
    rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
  fi

  if md_backup_exists /etc/salt/pki/minion; then
    log "Keeping restored Salt minion key backup"
  else
    rm -rf /etc/salt/pki/minion/* 2>/dev/null || true
  fi

  find /var/cache/salt/minion/extmods/modules -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
  find /var/cache/salt/minion/extmods -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
  find /etc/systemd/resolved.conf.d -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
}

restart_after_leave() {
  systemctl daemon-reload || true
  systemctl restart systemd-resolved.service 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || true
  systemctl restart sshd.service 2>/dev/null || true
}

leave_domain() {
  need_root
  setup_logging
  md_init_state

  warn "Leaving MultiDirectory domain"

  load_os_release

  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd awk
  need_cmd tr

  validate_leave_credentials
  log "Starting optional remote LDAP cleanup"
  disable_computer_account_on_leave
  log "Remote LDAP cleanup step completed"

  log "Starting local leave cleanup"
  stop_domain_services
  remove_managed_files
  restore_backups
  cleanup_domain_state

  rm -rf "$MD_ETC_DIR"

  restart_after_leave

  log "Local leave cleanup completed"
  log "MultiDirectory leave completed"
  warn "System reboot is recommended"
}

rollback_local_changes() {
  local code="$1"

  warn "Join failed with exit code ${code}"
  warn "Rolling back local configuration changes"
  warn "Server-side objects created via API are not removed by local rollback"

  mkdir -p "${MD_STATE_DIR}"
  touch "${MD_ROLLBACK_MARKER}"

  set +e

  stop_domain_services
  remove_managed_files
  restore_backups
  cleanup_domain_state
  restart_after_leave

  rm -f "${MD_ROLLBACK_MARKER}"

  set -e

  warn "Rollback completed"
}

on_join_error() {
  local code=$?

  trap - ERR

  rollback_local_changes "$code"

  exit "$code"
}

preflight() {
  need_root
  setup_logging
  load_os_release
  check_system_capabilities

  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd file
  need_cmd sed
  need_cmd awk
  need_cmd tr
  need_cmd hostname
  need_cmd klist
  need_cmd kinit
  need_cmd ldapwhoami
  need_cmd sort

  normalize_files_eol
}

join_domain() {
  preflight
  md_init_state

  trap on_join_error ERR

  load_or_prompt_edition
  validate_files_structure
  prompt_configure_dns

  while true; do
    read_tty API_HOST "Enter API address (FQDN), for example webadmin.domain.ru:"
    if [[ -z "${API_HOST}" ]]; then
      warn "API host must be filled."
      continue
    fi
    if getent hosts "${API_HOST}" >/dev/null; then
      log "DNS resolution OK: ${API_HOST}"
      SALT_MASTER="salt.${API_HOST}"
      if [[ "${WITH_SALT}" -eq 1 ]] && ! getent hosts "${SALT_MASTER}" >/dev/null; then
        warn "Salt master ${SALT_MASTER} does not resolve, but continuing."
      fi
      break
    else
      warn "DNS resolution failed for ${API_HOST}. Please check the address."
    fi
  done

  while true; do
    read_tty LOGIN "Enter administrator login, for example admin:"
    read_secret_tty PASSWORD "Enter administrator password:"
    if [[ -z "${LOGIN}" || -z "${PASSWORD}" ]]; then
      warn "Login and password must be filled."
      continue
    fi
    log "Authenticating domain administrator via API"
    if access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")" && [[ -n "${access_token}" ]]; then
      log "Domain administrator credentials are valid"
      break
    else
      warn "Authentication failed. Please check login and password."
    fi
  done
  discover_and_validate_domain

  prompt_change_hostname

  log "DOMAIN=${DOMAIN}"
  log "REALM=${REALM}"
  log "LDAP_BASE_DN=${LDAP_BASE_DN}"
  log "HOSTNAME=${HOSTNAME}"
  log "FQDN=${FQDN}"
  log "EDITION=${EDITION}"
  log "WITH_SALT=${WITH_SALT}"

  install_static_configs
  validate_no_password_based_sssd_auth
  validate_sssd_config

  create_computer_object_if_needed

  log "Getting keytab"
  api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${FQDN}"

  validate_keytab
  validate_ldap_gssapi_auth

  unset PASSWORD

  configure_salt

  save_join_env
  start_services

  trap - ERR

  log "Configuration completed successfully"
  warn "System reboot is recommended"
}

require_install_packages_launcher() {
  if [[ "${MD_CALLED_FROM_INSTALL_PACKAGES:-0}" != "1" ]]; then
    echo "[ERR] This script must be started only via install_packages.sh" > /dev/tty
    echo "[ERR] Run: ./install_packages.sh ${1:-join}" > /dev/tty
    exit 126
  fi
}

main() {
  require_install_packages_launcher "${1:-join}"

  case "${1:-}" in
    join)
      join_domain
      ;;
    leave)
      leave_domain
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
