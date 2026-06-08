#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
die()  { echo -e "${RED}$*${NC}" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Not found: $1"; }

read_tty() {
  local var="$1"
  local prompt="$2"
  echo -e "${YELLOW}${prompt}${NC}"
  IFS= read -r "$var" </dev/tty
}

read_secret_tty() {
  local var="$1"
  local prompt="$2"
  echo -e "${YELLOW}${prompt}${NC}"
  IFS= read -rs "$var" </dev/tty
  echo
}

is_altlinux() {
  [[ -f /etc/altlinux-release ]] || [[ -f /etc/os-release && "$(source /etc/os-release 2>/dev/null && echo "$ID")" == "altlinux" ]]
}

is_redos() {
  [[ -f /etc/os-release ]] && source /etc/os-release && [[ "$ID" == "redos" || "${ID_LIKE:-}" =~ (rhel|fedora) ]]
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
MD_ETC_DIR="/etc/MultiDirectory"
MD_STATE_DIR="${MD_ETC_DIR}/state"
MD_BACKUP_DIR="${MD_STATE_DIR}/backups"
MD_MANIFEST="${MD_STATE_DIR}/manifest"
MD_JOIN_ENV="${MD_STATE_DIR}/join.env"

need_local_file() {
  local p="$1"
  [[ -f "$p" ]] || die "Local file not found: $p"
  [[ -s "$p" ]] || die "Local file is empty: $p"
}

install_local_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0644}"
  need_local_file "$src"
  sudo install -m "$mode" -o root -g root "$src" "$dst"
}

apply_placeholders() {
  local file="$1"
  local esc_password esc_sssd_password

  esc_password="$(printf '%s' "$PASSWORD" | sed -e 's/[\/&]/\\&/g')"
  esc_sssd_password="$(printf '%s' "$SSSD_PASSWORD" | sed -e 's/[\/&]/\\&/g')"

  sudo sed -i \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s/__REALM__/${REALM}/g" \
    -e "s/__KDC__/${KDC}/g" \
    -e "s/__KADMIN__/${KADMIN}/g" \
    -e "s#__URI__#${URI}#g" \
    -e "s#__LDAP_SEARCH_BASE__#${LDAP_SEARCH_BASE}#g" \
    -e "s#__LDAP_USER_BASE__#${LDAP_USER_BASE}#g" \
    -e "s#__LDAP_GROUP_BASE__#${LDAP_SEARCH_BASE}#g" \
    -e "s#__BIND_DN__#${BIND_DN}#g" \
    -e "s/__PASSWORD__/${esc_password}/g" \
    -e "s#__SSSD_BIND_DN__#${SSSD_BIND_DN}#g" \
    -e "s/__SSSD_PASSWORD__/${esc_sssd_password}/g" \
    "$file"
}

valid_hostname() {
  local h="$1"
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

apply_hostname() {
  local new_short="$1"
  local new_fqdn
  if [[ -n "${DOMAIN:-}" ]]; then
    new_fqdn="${new_short}.${DOMAIN}"
  else
    warn "DOMAIN is not defined yet — setting hostname without domain: ${new_short}"
    new_fqdn="${new_short}"
  fi
  log "Renaming host: ${new_short} (${new_fqdn})"
  if command -v hostnamectl >/dev/null 2>&1; then
    sudo hostnamectl set-hostname "$new_fqdn"
  else
    echo "$new_fqdn" | sudo tee /etc/hostname >/dev/null
    sudo hostname "$new_fqdn" || true
  fi
  if [ -f /etc/hosts ]; then
    if grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
      sudo sed -i -E "s/^\s*127\.0\.1\.1\s+.*/127.0.1.1\t${new_fqdn} ${new_short}/" /etc/hosts
    else
      echo -e "127.0.1.1\t${new_fqdn} ${new_short}" | sudo tee -a /etc/hosts >/dev/null
    fi
  fi
  log "Current hostname: $(hostname)"
}

prompt_change_hostname() {
  local current
  current="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  echo -e "${YELLOW}Change PC name?${NC}"
  echo "1. No"
  echo "2. Yes"
  local choice
  while true; do
    echo -ne "${YELLOW}Select (1/2): ${NC}"
    IFS= read -r choice </dev/tty
    case "$choice" in
      1)
        HOSTNAME="$current"
        log "PC name left unchanged: ${HOSTNAME}"
        return 0
        ;;
      2)
        local new
        while true; do
          read_tty new "Enter new PC name (lowercase, a-z0-9-, up to 63 characters):"
          new="$(echo "$new" | tr '[:upper:]' '[:lower:]')"
          if valid_hostname "$new"; then
            HOSTNAME="$new"
            log "Selected new PC name: ${HOSTNAME}"
            apply_hostname "$HOSTNAME"
            return 0
          else
            warn "Invalid name: '${new}'. Example: pc-01, node1, ws-123"
          fi
        done
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

prompt_edition() {
  echo -e "${YELLOW}Select MultiDirectory edition:${NC}"
  echo "1. Enterprise"
  echo "2. Community"
  local choice
  while true; do
    echo -ne "${YELLOW}Select (1/2): ${NC}"
    IFS= read -r choice </dev/tty
    case "$choice" in
      1) EDITION="enterprise"; WITH_SALT=1; log "Selected edition: Enterprise"; return 0 ;;
      2) EDITION="community";  WITH_SALT=0; log "Selected edition: Community";  return 0 ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
}

md_set_resolv_first() {
  local ns="$1"
  sudo chattr -i /etc/resolv.conf 2>/dev/null || true
  local _tmp
  _tmp="$(mktemp)"
  echo "nameserver ${ns}" > "$_tmp"
  if [[ -f /etc/resolv.conf ]]; then
    grep -v "^nameserver ${ns}\$" /etc/resolv.conf >> "$_tmp" 2>/dev/null || true
  fi
  sudo cp "$_tmp" /etc/resolv.conf
  rm -f "$_tmp"
  sudo chattr +i /etc/resolv.conf 2>/dev/null || true
  log "DNS server ${ns} set as first nameserver in /etc/resolv.conf (file locked)"
}

prompt_configure_dns() {
  local choice
  echo -e "${YELLOW}Set MultiDirectory DNS server?${NC}"
  echo "1. Yes"
  echo "2. No"
  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"
    case "$choice" in
      1)
        local dns_ip
        while true; do
          read_tty dns_ip "Enter DNS server IP:"
          if [[ -n "${dns_ip}" ]] && [[ ! "$dns_ip" =~ [[:space:]] ]]; then
            break
          else
            warn "Invalid DNS server address. Please enter a non-empty value without spaces."
          fi
        done
        md_set_resolv_first "${dns_ip}"
        log "DNS configuration applied."
        return 0
        ;;
      2)
        log "DNS configuration skipped."
        return 0
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

api_auth_cookie() {
  local user="$1"
  local pass="$2"
  curl -k -sS -X POST "https://${API_HOST}/api/auth/" \
    -H "accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$user" \
    --data-urlencode "password=$pass" \
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
    ( .search_result[0].partial_attributes[]? | select(.type=="defaultNamingContext") | .vals[0] ) // empty
  '
}

api_rootdse_domain() {
  local cookie="$1"
  local resp
  resp="$(api_search "$cookie" "" 0 "(objectClass=*)" \
    "[\"dnsDomainName\",\"dnsForestName\",\"dnsHostName\",\"defaultNamingContext\"]")"
  local dom
  dom="$(printf '%s' "$resp" | jq -r '
    ( .search_result[0].partial_attributes[]? | select(.type=="dnsDomainName") | .vals[0] ) // empty
  ')"
  if [[ -z "${dom:-}" ]]; then
    dom="$(printf '%s' "$resp" | jq -r '
      ( .search_result[0].partial_attributes[]? | select(.type=="dnsForestName") | .vals[0] ) // empty
    ')"
  fi
  if [[ -z "${dom:-}" ]]; then
    dom="$(printf '%s' "$resp" | jq -r '
      ( .search_result[0].partial_attributes[]? | select(.type=="dnsHostName") | .vals[0] ) // empty
    ')"
  fi
  if [[ -z "${dom:-}" ]]; then
    local nc
    nc="$(printf '%s' "$resp" | jq -r '
      ( .search_result[0].partial_attributes[]? | select(.type=="defaultNamingContext") | .vals[0] ) // empty
    ')"
    if [[ -n "${nc:-}" ]]; then
      dom="$(printf '%s' "$nc" | awk -F',' '
        {
          out="";
          for(i=1;i<=NF;i++){
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i);
            if($i ~ /^dc=/){
              sub(/^dc=/,"",$i);
              out = (out=="" ? $i : out "." $i);
            }
          }
          print out
        }'
      )"
    fi
  fi
  printf '%s' "$dom"
}

api_principal_add() {
  local cookie="$1"
  local spn="$2"
  local primary="${spn%%/*}"
  local instance="${spn#*/}"
  curl -k -sS -X POST "https://${API_HOST}/api/kerberos/principal/add" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Cookie: id=${cookie}" \
    -d "{\"primary\":\"${primary}\",\"instance\":\"${instance}\"}" \
    -o /tmp/princ_add.body -w '%{http_code}' 2>/dev/null
}

api_ktadd_download() {
  local cookie="$1"
  local spn1="$2"
  local spn2="$3"
  sudo rm -f /tmp/ktadd.hdr /tmp/ktadd.body /etc/krb5.keytab
  local body
  if [[ "${EDITION}" == "community" ]]; then
    log "Community: registering principals via /api/kerberos/principal/add..."
    log "  ${spn1} -> HTTP $(api_principal_add "${cookie}" "${spn1}")"
    log "  ${spn2} -> HTTP $(api_principal_add "${cookie}" "${spn2}")"
    body="[\"${spn1}@${REALM}\",\"${spn2}@${REALM}\"]"
  else
    body="{\"names\":[\"${spn1}\",\"${spn2}\"],\"is_rand_key\":true}"
  fi
  curl -k -sS --fail-with-body \
    -D /tmp/ktadd.hdr \
    -o /tmp/ktadd.body \
    -X POST "https://${API_HOST}/api/kerberos/ktadd" \
    -H "accept: application/octet-stream" \
    -H "Content-Type: application/json" \
    -H "Cookie: id=${cookie}" \
    -d "${body}" || true
  log "ktadd headers (first 20 lines):"
  sed -n '1,20p' /tmp/ktadd.hdr || true
  log "ktadd file info:"
  ls -lh /tmp/ktadd.body || true
  file /tmp/ktadd.body || true
  if file /tmp/ktadd.body 2>/dev/null | grep -Ei 'json|text|html' >/dev/null; then
    warn "It looks like the API returned a non-binary keytab (JSON/HTML/text). First lines below:"
    head -n 60 /tmp/ktadd.body || true
    die "keytab was not received as a binary file. See /tmp/ktadd.hdr and /tmp/ktadd.body"
  fi
  sudo install -m 600 -o root -g root /tmp/ktadd.body /etc/krb5.keytab
  log "Keytab installed: /etc/krb5.keytab"
}

md_init_state() {
  sudo mkdir -p "$MD_STATE_DIR" "$MD_BACKUP_DIR"
  sudo touch "$MD_MANIFEST"
  sudo chmod 600 "$MD_MANIFEST"
}

md_backup_once() {
  local path="$1"
  local safe
  safe="$(echo "$path" | sed 's#/#__#g')"
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ ! -e "${MD_BACKUP_DIR}/${safe}" && ! -L "${MD_BACKUP_DIR}/${safe}" ]]; then
      sudo cp -a "$path" "${MD_BACKUP_DIR}/${safe}"
    fi
  fi
}

restore_one() {
  local path="$1"
  local safe
  safe="$(echo "$path" | sed 's#/#__#g')"
  if [[ -e "${MD_BACKUP_DIR}/${safe}" || -L "${MD_BACKUP_DIR}/${safe}" ]]; then
    sudo rm -rf "$path"
    sudo cp -a "${MD_BACKUP_DIR}/${safe}" "$path"
    log "Restored: $path"
  fi
}

md_track() {
  local path="$1"
  grep -Fxq "$path" "$MD_MANIFEST" 2>/dev/null || echo "$path" | sudo tee -a "$MD_MANIFEST" >/dev/null
}

md_save_join_env() {
  sudo tee "$MD_JOIN_ENV" >/dev/null <<EOF
DOMAIN='${DOMAIN}'
REALM='${REALM}'
HOSTNAME='${HOSTNAME}'
API_HOST='${API_HOST}'
LDAP_BASE_DN='${LDAP_BASE_DN}'
LDAP_COMPUTER_OU='${LDAP_COMPUTER_OU}'
WITH_SALT='${WITH_SALT}'
GUID='${guid:-}'
EOF
  sudo chmod 600 "$MD_JOIN_ENV"
}

leave_domain() {
  need_cmd curl
  need_cmd jq
  need_cmd sudo

  if [[ ! -f "$MD_JOIN_ENV" ]]; then
    log "No domain join state found, nothing to leave."
    return 0
  fi

  source "$MD_JOIN_ENV"

  read_tty API_HOST_INPUT "Enter API address for domain leave [${API_HOST}]:"
  API_HOST="${API_HOST_INPUT:-$API_HOST}"

  read_tty LOGIN "Enter domain administrator login:"
  read_secret_tty PASSWORD "Enter domain administrator password:"

  [[ -n "${LOGIN:-}" && -n "${PASSWORD:-}" ]] || die "Domain admin credentials are required for leave."

  log "Checking domain administrator credentials..."
  access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"
  if [[ -z "${access_token:-}" ]]; then
    warn "Invalid domain administrator credentials. Leave aborted."
    return 1
  fi
  log "Domain administrator credentials are valid."

  if [[ "${WITH_SALT:-0}" -eq 1 ]] && [[ -n "${GUID:-}" ]]; then
    log "Deleting Salt minion key from master (GUID=${GUID})..."
    resp=$(curl -k -sS -w "\n%{http_code}" -X DELETE "https://${API_HOST}/api/salt/minion/${GUID}" \
      -H "Cookie: id=${access_token}" \
      -H 'accept: application/json' 2>&1) || true
    http_code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [[ "$http_code" -eq 200 ]]; then
      log "Salt minion key successfully deleted."
    else
      warn "Failed to delete Salt minion key (HTTP $http_code): $body"
    fi
  else
    warn "Salt integration not enabled or GUID missing, skipping Salt minion deletion."
  fi

  if [[ -n "${HOSTNAME:-}" && -n "${LDAP_COMPUTER_OU:-}" ]]; then
    COMPUTER_DN="cn=${HOSTNAME},${LDAP_COMPUTER_OU}"
    log "Disabling computer object in LDAP: ${COMPUTER_DN}"
    payload="[{\"object\":\"${COMPUTER_DN}\",\"changes\":[{\"operation\":2,\"modification\":{\"type\":\"userAccountControl\",\"vals\":[\"4098\"]}}]}]"
    resp=$(curl -k -sS -w "\n%{http_code}" -X PATCH "https://${API_HOST}/api/entry/update_many" \
      -H "Cookie: id=${access_token}" \
      -H 'Content-Type: application/json' \
      -d "$payload" 2>&1) || true
    http_code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [[ "$http_code" -eq 200 ]]; then
      log "Computer object disabled successfully."
    else
      warn "Failed to disable computer object (HTTP $http_code): $body"
    fi
  else
    warn "HOSTNAME or LDAP_COMPUTER_OU missing, skipping LDAP computer disable."
  fi

  warn "Computer object will NOT be deleted from LDAP/domain (only disabled)."

  sudo systemctl stop sssd.service 2>/dev/null || true
  sudo systemctl stop salt-minion.service 2>/dev/null || true
  sudo systemctl disable salt-minion.service 2>/dev/null || true

  sudo chattr -i /etc/resolv.conf 2>/dev/null || true

  if [[ -f "$MD_MANIFEST" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      [[ "$p" == "/" ]] && continue
      if [[ -L "$p" || -f "$p" ]]; then
        sudo rm -f "$p"
      fi
    done < "$MD_MANIFEST"
  fi

  restore_one /etc/krb5.conf
  restore_one /etc/sssd/sssd.conf
  restore_one /etc/nsswitch.conf
  restore_one /etc/hostname
  restore_one /etc/hosts
  sudo chattr -i /etc/resolv.conf 2>/dev/null || true
  restore_one /etc/resolv.conf
  restore_one /etc/pam.d/system-auth
  restore_one /etc/pam.d/su
  restore_one /etc/pam.d/sshd
  restore_one /etc/pam.d/gdm-password
  restore_one /etc/pam.d/common-auth
  restore_one /etc/pam.d/common-account
  restore_one /etc/pam.d/common-session
  restore_one /etc/pam.d/common-password
  restore_one /etc/salt/minion
  restore_one /etc/salt/minion_id
  restore_one /etc/salt/pki/minion
  restore_one /etc/systemd/resolved.conf.d/MultiDirectory.conf
  sudo rm -f /etc/systemd/system/sssd.service.d/md-wait-network.conf 2>/dev/null || true
  sudo systemctl unmask sssd-nss.socket sssd-pam.socket sssd-ssh.socket sssd-sudo.socket sssd-autofs.socket sssd-pac.socket >/dev/null 2>&1 || true
  sudo systemctl daemon-reload 2>/dev/null || true

  sudo rm -f /etc/krb5.keytab
  sudo rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
  sudo rm -rf /etc/salt/pki/minion/* 2>/dev/null || true
  sudo rm -f /etc/sudoers.d/multidirectory-domain-admins
  sudo rm -f /etc/systemd/resolved.conf.d/MultiDirectory.conf

  sudo rm -rf "$MD_ETC_DIR"

  sudo systemctl daemon-reload 2>/dev/null || true
  sudo systemctl restart systemd-resolved.service 2>/dev/null || true
  sudo systemctl restart ssh.service 2>/dev/null || true
  sudo systemctl restart sshd.service 2>/dev/null || true

  log "MULTIDIRECTORY leave completed."
  warn "System reboot is recommended."
}

join_domain() {
  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd file
  need_cmd sudo
  need_cmd sed
  need_cmd awk
  need_cmd tr
  need_cmd head
  need_cmd hostname

  md_init_state

  prompt_edition
  prompt_configure_dns

  read_tty API_HOST "Enter API address (FQDN), for example webadmin.domain.ru:"
  read_tty LOGIN    "Enter administrator login (for example, admin):"
  read_secret_tty PASSWORD "Enter administrator password:"

  echo
  warn "Specify the service user for SSSD."
  read_tty SSSD_LOGIN           "Enter LDAP service user login for SSSD (for example, sssd_bind):"
  read_secret_tty SSSD_PASSWORD "Enter LDAP service user password for SSSD:"

  [[ -n "${API_HOST:-}" && -n "${LOGIN:-}" && -n "${PASSWORD:-}" && -n "${SSSD_LOGIN:-}" && -n "${SSSD_PASSWORD:-}" ]] \
    || die "Error: all fields must be filled."

  log "Checking DNS resolution: API_HOST=${API_HOST}"
  getent hosts "${API_HOST}" >/dev/null || die "DNS resolution failed: ${API_HOST}"

  log "Getting cookie id (admin) via API /api/auth/..."
  access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"
  [[ -n "${access_token:-}" ]] || die "Failed to get cookie id"
  log "cookie id (admin) received"

  log "Detecting DOMAIN via API RootDSE..."
  DOMAIN="$(api_rootdse_domain "${access_token}")"
  [[ -n "${DOMAIN:-}" ]] || die "Failed to detect DOMAIN via API RootDSE"
  log "DOMAIN=${DOMAIN}"

  log "Getting defaultNamingContext (base DN) via API (RootDSE)..."
  LDAP_BASE_DN="$(api_rootdse_default_nc "${access_token}")"
  [[ -n "${LDAP_BASE_DN:-}" ]] || die "Failed to get defaultNamingContext via API"
  log "LDAP_BASE_DN=${LDAP_BASE_DN}"

  if [[ "${API_HOST}" != "${DOMAIN}" ]]; then
    warn "API_HOST (${API_HOST}) differs from DOMAIN (${DOMAIN}) — this is normal."
  fi

  prompt_change_hostname

  log "Getting administrator DN via API /api/entry/search..."
  USER_FILTER="(sAMAccountName=${LOGIN})"
  binddn_resp="$(api_search "${access_token}" "${LDAP_BASE_DN}" 2 "${USER_FILTER}" "[\"distinguishedName\"]")"
  BIND_DN="$(printf '%s' "$binddn_resp" | jq -r '.search_result[0].object_name // empty')"
  if [[ -z "${BIND_DN:-}" ]]; then
    warn "Administrator DN was not received via API. Manual DN input is required."
    read_tty BIND_DN "Enter administrator DN (example: cn=admin,cn=users,dc=domain,dc=ru):"
  fi
  [[ -n "${BIND_DN:-}" ]] || die "Administrator DN is empty"
  log "Admin DN=${BIND_DN}"

  log "Getting SSSD service user DN via API /api/entry/search..."
  SSSD_FILTER="(sAMAccountName=${SSSD_LOGIN})"
  sssd_dn_resp="$(api_search "${access_token}" "${LDAP_BASE_DN}" 2 "${SSSD_FILTER}" "[\"distinguishedName\"]")"
  SSSD_BIND_DN="$(printf '%s' "$sssd_dn_resp" | jq -r '.search_result[0].object_name // empty')"
  if [[ -z "${SSSD_BIND_DN:-}" ]]; then
    warn "SSSD service user DN was not received via API. Manual DN input is required."
    read_tty SSSD_BIND_DN "Enter SSSD service user DN (example: cn=sssd_bind,cn=users,dc=domain,dc=ru):"
  fi
  [[ -n "${SSSD_BIND_DN:-}" ]] || die "SSSD_BIND_DN is empty"
  log "SSSD bind DN=${SSSD_BIND_DN}"

  REALM="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"
  KDC="$DOMAIN"
  KADMIN="$DOMAIN"
  URI="ldap://${DOMAIN}"
  LDAP_SEARCH_BASE="$LDAP_BASE_DN"
  LDAP_USER_BASE="$LDAP_BASE_DN"
  LDAP_COMPUTER_OU="cn=computers,${LDAP_BASE_DN}"
  SUDO_GROUP='"%domain admins" ALL=(ALL) ALL'

  if [[ "${WITH_SALT}" -eq 1 ]]; then
    SALT_MASTER="salt.${DOMAIN}"
    log "Checking DNS resolution: SALT_MASTER=${SALT_MASTER}"
    if ! getent hosts "${SALT_MASTER}" >/dev/null; then
      warn "DNS resolution for SALT_MASTER=${SALT_MASTER} failed. Please ensure DNS is correct."
    fi
  fi

  log "REALM=${REALM} HOSTNAME=${HOSTNAME} API_HOST=${API_HOST} DOMAIN=${DOMAIN}"

  sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.bak 2>/dev/null || true

  log "Taking configs LOCALLY from: ${FILES_DIR}"

  KRB5_CONF_LOCAL="${FILES_DIR}/krb5.conf"
  SSSD_CONF_LOCAL="${FILES_DIR}/sssd.conf"
  NSSWITCH_CONF_LOCAL="${FILES_DIR}/nsswitch.conf"
  SSH_MD_CONF_LOCAL="${FILES_DIR}/ssh_md.conf"

  need_local_file "$KRB5_CONF_LOCAL"
  need_local_file "$SSSD_CONF_LOCAL"
  need_local_file "$NSSWITCH_CONF_LOCAL"
  need_local_file "$SSH_MD_CONF_LOCAL"

  log "Installing /etc/krb5.conf from local file..."
  install_local_file "$KRB5_CONF_LOCAL" /etc/krb5.conf 0644
  apply_placeholders /etc/krb5.conf

  log "Installing /etc/sssd/sssd.conf from local file..."
  sudo mkdir -p /etc/sssd
  install_local_file "$SSSD_CONF_LOCAL" /etc/sssd/sssd.conf 0600
  apply_placeholders /etc/sssd/sssd.conf
  sudo chown root:root /etc/sssd/sssd.conf

  log "Installing /etc/nsswitch.conf from local file..."
  install_local_file "$NSSWITCH_CONF_LOCAL" /etc/nsswitch.conf 0644

  log "Installing /etc/ssh/sshd_config.d/ssh_md.conf from local file..."
  sudo mkdir -p /etc/ssh/sshd_config.d
  install_local_file "$SSH_MD_CONF_LOCAL" /etc/ssh/sshd_config.d/ssh_md.conf 0644

  log "Encrypting SSSD password (sss_obfuscate)..."
  warn "Enter the service account password for encryption"
  sudo sss_obfuscate -d "${DOMAIN}"

  if is_redos; then
    if command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y authselect oddjob 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y authselect oddjob 2>/dev/null
    fi
    sudo authselect select sssd with-mkhomedir --force 2>/dev/null
    sudo systemctl enable --now oddjobd.service 2>/dev/null
  elif is_altlinux; then
    sudo chmod 4711 /usr/bin/sudo >/dev/null 2>&1
    sudo tee /etc/pam.d/system-auth >/dev/null <<'EOF'
#%PAM-1.0
auth        sufficient    pam_sss.so
auth        required      pam_permit.so

account     sufficient    pam_sss.so
account     required      pam_permit.so

password    sufficient    pam_sss.so
password    required      pam_permit.so

session     sufficient    pam_sss.so
session     required      pam_permit.so
session     required      pam_mkhomedir.so skel=/etc/skel umask=0022
EOF
    sudo tee /etc/pam.d/su >/dev/null <<'EOF'
#%PAM-1.0
auth            sufficient      pam_rootok.so
auth            include         system-auth
account         include         system-auth
password        required        pam_deny.so
session         required        pam_mkhomedir.so skel=/etc/skel umask=0022
session         include         system-auth
session         optional        pam_xauth.so
EOF
    sudo tee /etc/pam.d/sshd >/dev/null <<'EOF'
#%PAM-1.0
auth        include      system-auth
account     required     pam_nologin.so
account     include      system-auth
password    include      system-auth
session     required     pam_mkhomedir.so skel=/etc/skel umask=0022
session     optional     pam_keyinit.so force revoke
session     include      system-auth
session     required     pam_loginuid.so
EOF
    if [ -f /etc/pam.d/gdm-password ]; then
      sudo tee /etc/pam.d/gdm-password >/dev/null <<'EOF'
#%PAM-1.0
auth            required        pam_shells.so
auth            required        pam_succeed_if.so quiet uid ne 0
auth            sufficient      pam_succeed_if.so user ingroup nopasswdlogin
auth            substack        common-login
auth            optional        pam_gnome_keyring.so
account         include         common-login
password        include         common-login
password        optional        pam_gnome_keyring.so use_authtok
session         required        pam_mkhomedir.so skel=/etc/skel umask=0022
session         substack        common-login
session         optional        pam_console.so
session         required        pam_namespace.so
session         optional        pam_gnome_keyring.so auto_start
EOF
    fi
  else
    log "Configuring PAM mkhomedir for Debian/Ubuntu"
    if [ -f /etc/pam.d/common-session ]; then
      sudo pam-auth-update --enable mkhomedir >/dev/null || true
      sudo sed -i 's/session optional pam_mkhomedir.so/session required pam_mkhomedir.so/' /etc/pam.d/common-session || true
    elif [ -f /etc/pam.d/system-auth ]; then
      if ! grep -q "pam_mkhomedir.so" /etc/pam.d/system-auth; then
        sudo sed -i '/session.*required.*pam_unix.so/a session     required      pam_mkhomedir.so skel=/etc/skel umask=0077' /etc/pam.d/system-auth
      fi
    fi
  fi

  log "Configuring sudoers"
  if ! grep -Fxq "$SUDO_GROUP" /etc/sudoers; then
    echo "$SUDO_GROUP" | sudo tee -a /etc/sudoers >/dev/null
  else
    log "sudo permissions for domain admins are already configured."
  fi

  log "Checking whether computer cn=${HOSTNAME} exists..."
  exists_cn="$(
    api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=computer)(cn=${HOSTNAME}))" "[\"cn\"]" \
    | jq -r '.search_result[0].object_name // empty'
  )"
  if [[ -n "${exists_cn:-}" ]]; then
    warn "Computer already exists in LDAP: ${exists_cn}. Adding will be skipped."
    SKIP_ADD_COMPUTER=1
  else
    SKIP_ADD_COMPUTER=0
  fi

  if [[ "${SKIP_ADD_COMPUTER}" -eq 0 ]]; then
    log "Creating computer object..."
    curl -k -sS -X POST "https://${API_HOST}/api/entry/add" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Cookie: id=${access_token}" \
      -d "{
        \"entry\": \"cn=${HOSTNAME},${LDAP_COMPUTER_OU}\",
        \"attributes\": [
          { \"type\": \"objectClass\", \"vals\": [\"top\",\"computer\"] },
          { \"type\": \"description\", \"vals\": [\"\"] }
        ]
      }" >/dev/null || true
  else
    log "Skipping /api/entry/add (computer already exists)."
  fi

  log "Getting keytab via API_HOST=${API_HOST}..."
  api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${HOSTNAME}.${DOMAIN}"

  log "Checking keytab:"
  sudo klist -k /etc/krb5.keytab || true

  if [[ "${WITH_SALT}" -eq 1 ]]; then
    log "Enterprise: configuring Salt..."

    if systemctl is-active --quiet salt-minion.service 2>/dev/null; then
      log "Stopping salt-minion service before reconfiguration..."
      sudo systemctl stop salt-minion.service
    fi

    if [[ -d /etc/salt/pki/minion ]]; then
      log "Removing existing Salt minion keys to force regeneration..."
      sudo rm -rf /etc/salt/pki/minion
    fi

    log "Getting master_finger for Salt (via API_HOST)..."
    gpo_token="$(curl -k -sS -X GET "https://${API_HOST}/api/salt/master/key" \
      -H "Cookie: id=${access_token}" \
      -H 'accept: application/json' | tr -d '\r\n')"
    [[ -n "${gpo_token:-}" ]] || die "Failed to get master_finger"

    log "Configuring /etc/salt/minion: master=${SALT_MASTER}"
    sudo mkdir -p /etc/salt
    sudo sed -i '/^\s*master:/d' /etc/salt/minion 2>/dev/null || true
    sudo sed -i '/^\s*master_finger:/d' /etc/salt/minion 2>/dev/null || true
    {
      echo "master: ${SALT_MASTER}"
      echo "master_finger: ${gpo_token}"
    } | sudo tee -a /etc/salt/minion >/dev/null

    log "Getting computer GUID..."
    guid="$(
      api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=*)(cn=${HOSTNAME}))" "[\"objectGUID\"]" \
      | jq -r '.search_result[0].partial_attributes[]? | select(.type=="objectGUID") | .vals[0] // empty'
    )"
    [[ -n "${guid:-}" ]] || die "Failed to get objectGUID"
    log "GUID=${guid}"

    if [ "$(cat /etc/salt/minion_id 2>/dev/null || true)" != "$guid" ]; then
      printf '%s\n' "$guid" | sudo tee /etc/salt/minion_id >/dev/null
    fi

    log "Starting salt-minion service..."
    sudo systemctl enable salt-minion.service >/dev/null 2>&1 || true
    sudo systemctl restart salt-minion.service

    accept_salt_key() {
      local retries=10
      local delay=3
      local attempt=1
      local resp
      local http_code
      local body

      while [[ $attempt -le $retries ]]; do
        log "Attempt $attempt/$retries: calling /api/salt/minion for id=${guid}"
        resp=$(curl -k -sS -w "\n%{http_code}" -X POST "https://${API_HOST}/api/salt/minion" \
          -H 'accept: application/json' \
          -H "Cookie: id=${access_token}" \
          -H 'Content-Type: application/json' \
          -d "{\"id\": \"${guid}\"}" 2>&1) || true
        http_code=$(echo "$resp" | tail -n1)
        body=$(echo "$resp" | sed '$d')
        log "HTTP response code: $http_code"
        if [[ "$http_code" -eq 200 ]]; then
          log "Salt minion key successfully accepted by API."
          return 0
        elif [[ "$http_code" -eq 400 ]] && echo "$body" | grep -q "Minion Already Exists"; then
          warn "Minion ${guid} already exists on master. Deleting it first..."
          curl -k -sS -X DELETE "https://${API_HOST}/api/salt/minion/${guid}" \
            -H "Cookie: id=${access_token}" \
            -H 'accept: application/json' \
            -o /dev/null || warn "DELETE failed, continuing anyway"
          sleep 2
          log "Restarting salt-minion to generate new keys..."
          sudo systemctl restart salt-minion.service
          sleep 5
          continue
        else
          warn "API returned $http_code: $body"
          sleep $delay
          ((attempt++))
        fi
      done
      die "Failed to accept Salt minion key after $retries attempts."
    }

    accept_salt_key
    sudo systemctl restart salt-minion.service
  else
    log "Community: Salt steps skipped."
  fi

  log "Starting services..."
  sudo systemctl daemon-reload >/dev/null 2>&1 || true

  if command -v sshd >/dev/null 2>&1; then
    sudo sshd -t || die "Error in sshd configuration"
    log "Success: sshd configuration check"
  fi

  if [[ "${WITH_SALT}" -eq 1 ]]; then
    services=(sssd ssh sshd salt-minion)
  else
    services=(sssd ssh sshd)
  fi

  for svc in "${services[@]}"; do
    log "Restarting service: ${svc}"
    sudo systemctl enable "${svc}.service" >/dev/null 2>&1 || true
    sudo systemctl restart "${svc}.service" >/dev/null 2>&1 || true
  done

  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
      log "ACTIVE: ${svc}"
    else
      warn "NOT ACTIVE: ${svc}"
      sudo systemctl status "${svc}.service" --no-pager -l 2>/dev/null || true
    fi
  done

  md_save_join_env

  log "Configuration completed successfully."
  warn "System reboot is recommended to apply all changes."
}

case "${1:-join}" in
  join)
    join_domain
    ;;
  leave)
    leave_domain
    ;;
  *)
    echo "Usage: $0 {join|leave}"
    exit 1
    ;;
esac