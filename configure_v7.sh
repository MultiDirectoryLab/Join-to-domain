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

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Не найдено: $1"; }

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

# ---------- local files helpers ----------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"

need_local_file() {
  local p="$1"
  [[ -f "$p" ]] || die "Не найден локальный файл: $p"
  [[ -s "$p" ]] || die "Локальный файл пустой: $p"
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

  # DOMAIN может быть ещё не определён (set -u), поэтому защищаемся
  if [[ -n "${DOMAIN:-}" ]]; then
    new_fqdn="${new_short}.${DOMAIN}"
  else
    warn "DOMAIN ещё не определён — ставлю hostname без домена: ${new_short}"
    new_fqdn="${new_short}"
  fi

  log "Переименование хоста: ${new_short} (${new_fqdn})"

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

  log "Текущее имя хоста: $(hostname)"
}

prompt_change_hostname() {
  local current
  current="$(hostname -s | tr '[:upper:]' '[:lower:]')"

  echo -e "${YELLOW}Изменить имя ПК?${NC}"
  echo "1. Нет"
  echo "2. Да"

  local choice
  while true; do
    echo -ne "${YELLOW}Выберите (1/2): ${NC}"
    IFS= read -r choice </dev/tty
    case "$choice" in
      1)
        HOSTNAME="$current"
        log "Имя ПК оставлено: ${HOSTNAME}"
        return 0
        ;;
      2)
        local new
        while true; do
          read_tty new "Введите новое имя ПК (lowercase, a-z0-9-, до 63 символов):"
          new="$(echo "$new" | tr '[:upper:]' '[:lower:]')"
          if valid_hostname "$new"; then
            HOSTNAME="$new"
            log "Выбрано новое имя ПК: ${HOSTNAME}"
            apply_hostname "$HOSTNAME"
            return 0
          else
            warn "Некорректное имя: '${new}'. Пример: pc-01, node1, ws-123"
          fi
        done
        ;;
      *)
        warn "Введите 1 или 2."
        ;;
    esac
  done
}

prompt_edition() {
  echo -e "${YELLOW}Выберите редакцию MultiDirectory:${NC}"
  echo "1. Enterprise"
  echo "2. Community"

  local choice
  while true; do
    echo -ne "${YELLOW}Выберите (1/2): ${NC}"
    IFS= read -r choice </dev/tty
    case "$choice" in
      1) EDITION="enterprise"; WITH_SALT=1; log "Выбрана редакция: Enterprise"; return 0 ;;
      2) EDITION="community";  WITH_SALT=0; log "Выбрана редакция: Community";  return 0 ;;
      *) warn "Введите 1 или 2." ;;
    esac
  done
}

# ----------------- API helpers (все на API_HOST) -----------------

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
    (
      .search_result[0].partial_attributes[]?
      | select(.type=="defaultNamingContext")
      | .vals[0]
    ) // empty
  '
}

api_rootdse_domain() {
  local cookie="$1"
  local resp
  resp="$(api_search "$cookie" "" 0 "(objectClass=*)" \
    "[\"dnsDomainName\",\"dnsForestName\",\"dnsHostName\",\"defaultNamingContext\"]")"

  local dom
  dom="$(printf '%s' "$resp" | jq -r '
    (
      .search_result[0].partial_attributes[]?
      | select(.type=="dnsDomainName")
      | .vals[0]
    ) // empty
  ')"

  if [[ -z "${dom:-}" ]]; then
    dom="$(printf '%s' "$resp" | jq -r '
      (
        .search_result[0].partial_attributes[]?
        | select(.type=="dnsForestName")
        | .vals[0]
      ) // empty
    ')"
  fi

  if [[ -z "${dom:-}" ]]; then
    dom="$(printf '%s' "$resp" | jq -r '
      (
        .search_result[0].partial_attributes[]?
        | select(.type=="dnsHostName")
        | .vals[0]
      ) // empty
    ')"
  fi

  if [[ -z "${dom:-}" ]]; then
    local nc
    nc="$(printf '%s' "$resp" | jq -r '
      (
        .search_result[0].partial_attributes[]?
        | select(.type=="defaultNamingContext")
        | .vals[0]
      ) // empty
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

api_ktadd_download() {
  local cookie="$1"
  local spn1="$2"
  local spn2="$3"

  sudo rm -f /tmp/ktadd.hdr /tmp/ktadd.body /etc/krb5.keytab

  curl -k -sS --fail-with-body \
    -D /tmp/ktadd.hdr \
    -o /tmp/ktadd.body \
    -X POST "https://${API_HOST}/api/kerberos/ktadd" \
    -H "accept: application/octet-stream" \
    -H "Content-Type: application/json" \
    -H "Cookie: id=${cookie}" \
    -d "{
      \"names\": [
        \"${spn1}\",
        \"${spn2}\"
      ],
      \"is_rand_key\": true
    }" || true

  log "ktadd headers (first 20 lines):"
  sed -n '1,20p' /tmp/ktadd.hdr || true

  log "ktadd file info:"
  ls -lh /tmp/ktadd.body || true
  file /tmp/ktadd.body || true

  if file /tmp/ktadd.body 2>/dev/null | grep -Ei 'json|text|html' >/dev/null; then
    warn "Похоже, API вернул не бинарный keytab (JSON/HTML/текст). Ниже первые строки:"
    head -n 60 /tmp/ktadd.body || true
    die "keytab не был получен как бинарник. См. /tmp/ktadd.hdr и /tmp/ktadd.body"
  fi

  sudo install -m 600 -o root -g root /tmp/ktadd.body /etc/krb5.keytab
  log "Keytab установлен: /etc/krb5.keytab"
}

# ----------------- Input -----------------

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

prompt_edition

read_tty API_HOST "Введите адрес API (FQDN), например webadmin.domain.ru:"
read_tty LOGIN    "Введите логин администратора (например, admin):"
read_secret_tty PASSWORD "Введите пароль администратора:"

echo
warn "Укажите сервисного пользователя для SSSD."
read_tty SSSD_LOGIN           "Введите логин сервисного пользователя LDAP для SSSD (например, sssd_bind):"
read_secret_tty SSSD_PASSWORD "Введите пароль сервисного пользователя LDAP для SSSD:"

[[ -n "${API_HOST:-}" && -n "${LOGIN:-}" && -n "${PASSWORD:-}" && -n "${SSSD_LOGIN:-}" && -n "${SSSD_PASSWORD:-}" ]] \
  || die "Ошибка: все поля должны быть заполнены."

log "Проверка DNS-резолва: API_HOST=${API_HOST}"
getent hosts "${API_HOST}" >/dev/null || die "DNS-резолв не выполнен: ${API_HOST}"

# ----------------- Admin auth -----------------

log "Получение cookie id (admin) через API /api/auth/..."
access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"
[[ -n "${access_token:-}" ]] || die "Не удалось получить cookie id"
log "cookie id (admin) получен"

# ----------------- Auto-detect DOMAIN + baseDN via RootDSE -----------------

log "Определение DOMAIN через API RootDSE..."
DOMAIN="$(api_rootdse_domain "${access_token}")"
[[ -n "${DOMAIN:-}" ]] || die "Не удалось определить DOMAIN через API RootDSE"
log "DOMAIN=${DOMAIN}"

log "Получение defaultNamingContext (base DN) через API (RootDSE)..."
LDAP_BASE_DN="$(api_rootdse_default_nc "${access_token}")"
[[ -n "${LDAP_BASE_DN:-}" ]] || die "Не удалось получить defaultNamingContext через API"
log "LDAP_BASE_DN=${LDAP_BASE_DN}"

if [[ "${API_HOST}" != "${DOMAIN}" ]]; then
  warn "API_HOST (${API_HOST}) отличается от DOMAIN (${DOMAIN}) — это нормально."
fi

prompt_change_hostname

# ----------------- DN admin/sssd via API -----------------

log "Получение DN администратора через API /api/entry/search..."
USER_FILTER="(sAMAccountName=${LOGIN})"
binddn_resp="$(api_search "${access_token}" "${LDAP_BASE_DN}" 2 "${USER_FILTER}" "[\"distinguishedName\"]")"
BIND_DN="$(printf '%s' "$binddn_resp" | jq -r '.search_result[0].object_name // empty')"
if [[ -z "${BIND_DN:-}" ]]; then
  warn "DN администратора не получен через API. Требуется ввод DN вручную."
  read_tty BIND_DN "Введите DN администратора (пример: cn=admin,cn=users,dc=domain,dc=ru):"
fi
[[ -n "${BIND_DN:-}" ]] || die "DN администратора пустой"
log "Admin DN=${BIND_DN}"

log "Получение DN сервисного пользователя SSSD через API /api/entry/search..."
SSSD_FILTER="(sAMAccountName=${SSSD_LOGIN})"
sssd_dn_resp="$(api_search "${access_token}" "${LDAP_BASE_DN}" 2 "${SSSD_FILTER}" "[\"distinguishedName\"]")"
SSSD_BIND_DN="$(printf '%s' "$sssd_dn_resp" | jq -r '.search_result[0].object_name // empty')"
if [[ -z "${SSSD_BIND_DN:-}" ]]; then
  warn "DN сервисного пользователя SSSD не получен через API. Требуется ввод DN вручную."
  read_tty SSSD_BIND_DN "Введите DN сервисного пользователя SSSD (пример: cn=sssd_bind,cn=users,dc=domain,dc=ru):"
fi
[[ -n "${SSSD_BIND_DN:-}" ]] || die "SSSD_BIND_DN пустой"
log "SSSD bind DN=${SSSD_BIND_DN}"

# ----------------- Derived vars (после определения DOMAIN) -----------------

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
  log "Проверка DNS-резолва: SALT_MASTER=${SALT_MASTER}"
  getent hosts "${SALT_MASTER}" >/dev/null || die "DNS-резолв не выполнен: ${SALT_MASTER}"
fi

log "REALM=${REALM} HOSTNAME=${HOSTNAME} API_HOST=${API_HOST} DOMAIN=${DOMAIN}"

sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.bak 2>/dev/null || true

# ----------------- Config files (LOCAL) -----------------

log "Конфиги берём ЛОКАЛЬНО из: ${FILES_DIR}"

KRB5_CONF_LOCAL="${FILES_DIR}/krb5.conf"
SSSD_CONF_LOCAL="${FILES_DIR}/sssd.conf"
NSSWITCH_CONF_LOCAL="${FILES_DIR}/nsswitch.conf"
SSH_MD_CONF_LOCAL="${FILES_DIR}/ssh_md.conf"

need_local_file "$KRB5_CONF_LOCAL"
need_local_file "$SSSD_CONF_LOCAL"
need_local_file "$NSSWITCH_CONF_LOCAL"
need_local_file "$SSH_MD_CONF_LOCAL"

log "Установка /etc/krb5.conf из локального файла..."
install_local_file "$KRB5_CONF_LOCAL" /etc/krb5.conf 0644
apply_placeholders /etc/krb5.conf

log "Установка /etc/sssd/sssd.conf из локального файла..."
sudo mkdir -p /etc/sssd
install_local_file "$SSSD_CONF_LOCAL" /etc/sssd/sssd.conf 0600
apply_placeholders /etc/sssd/sssd.conf
sudo chown root:root /etc/sssd/sssd.conf

log "Установка /etc/nsswitch.conf из локального файла..."
install_local_file "$NSSWITCH_CONF_LOCAL" /etc/nsswitch.conf 0644

log "Установка /etc/ssh/sshd_config.d/ssh_md.conf из локального файла..."
sudo mkdir -p /etc/ssh/sshd_config.d
install_local_file "$SSH_MD_CONF_LOCAL" /etc/ssh/sshd_config.d/ssh_md.conf 0644

log "Шифрование пароля SSSD (sss_obfuscate)..."
warn "Введите пароль сервисной учетной записи для шифрования"
sudo sss_obfuscate -d "${DOMAIN}"

# ----------------- PAM mkhomedir -----------------

log "Настройка PAM mkhomedir..."
if [ -f /etc/pam.d/common-session ]; then
  sudo pam-auth-update --enable mkhomedir >/dev/null || true
  sudo sed -i 's/session optional pam_mkhomedir.so/session required pam_mkhomedir.so/' /etc/pam.d/common-session || true
elif [ -f /etc/pam.d/system-auth ]; then
  if ! grep -q "pam_mkhomedir.so" /etc/pam.d/system-auth; then
    sudo sed -i '/session.*required.*pam_unix.so/a session     required      pam_mkhomedir.so skel=/etc/skel umask=0077' /etc/pam.d/system-auth
  fi
fi

# ----------------- sudoers -----------------

log "Настройка sudoers..."
if ! grep -Fxq "$SUDO_GROUP" /etc/sudoers; then
  echo "$SUDO_GROUP" | sudo tee -a /etc/sudoers >/dev/null
else
  log "Права sudo для domain admins уже настроены."
fi

# ----------------- Computer object + keytab via API -----------------

log "Проверка, существует ли компьютер cn=${HOSTNAME}..."
exists_cn="$(
  api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=computer)(cn=${HOSTNAME}))" "[\"cn\"]" \
  | jq -r '.search_result[0].object_name // empty'
)"
if [[ -n "${exists_cn:-}" ]]; then
  warn "Компьютер уже существует в LDAP: ${exists_cn}. Добавление будет пропущено."
  SKIP_ADD_COMPUTER=1
else
  SKIP_ADD_COMPUTER=0
fi

if [[ "${SKIP_ADD_COMPUTER}" -eq 0 ]]; then
  log "Создание computer-объекта..."
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
  log "Пропуск /api/entry/add (computer уже существует)."
fi

log "Получение keytab через API_HOST=${API_HOST}..."
api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${HOSTNAME}.${DOMAIN}"

log "Проверка keytab:"
sudo klist -k /etc/krb5.keytab || true

# ----------------- Salt (Enterprise only) -----------------

if [[ "${WITH_SALT}" -eq 1 ]]; then
  log "Enterprise: настройка Salt..."

  log "Получение master_finger для Salt (через API_HOST)..."
  gpo_token="$(curl -k -sS -X GET "https://${API_HOST}/api/salt/master/key" \
    -H "Cookie: id=${access_token}" \
    -H 'accept: application/json' | tr -d '\r\n')"
  [[ -n "${gpo_token:-}" ]] || die "Не удалось получить master_finger"

  log "Настройка /etc/salt/minion: master=${SALT_MASTER}"
  sudo sed -i '/^\s*master:/d' /etc/salt/minion 2>/dev/null || true
  sudo sed -i '/^\s*master_finger:/d' /etc/salt/minion 2>/dev/null || true
  {
    echo "master: ${SALT_MASTER}"
    echo "master_finger: ${gpo_token}"
  } | sudo tee -a /etc/salt/minion >/dev/null

  log "Получение GUID компьютера..."
  guid="$(
    api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=*)(cn=${HOSTNAME}))" "[\"objectGUID\"]" \
    | jq -r '.search_result[0].partial_attributes[]? | select(.type=="objectGUID") | .vals[0] // empty'
  )"
  [[ -n "${guid:-}" ]] || die "Не удалось получить objectGUID"
  log "GUID=${guid}"

  if [ "$(cat /etc/salt/minion_id 2>/dev/null || true)" != "$guid" ]; then
    printf '%s\n' "$guid" | sudo tee /etc/salt/minion_id >/dev/null
  fi
else
  log "Community: Salt-шаги пропущены."
fi

# ----------------- Restart services -----------------

log "Запуск служб..."
sudo systemctl daemon-reload >/dev/null 2>&1 || true

if command -v sshd >/dev/null 2>&1; then
  sudo sshd -t || die "Ошибка в конфигурации sshd"
  log "Успешно: Проверка конфигурации sshd"
fi

if [[ "${WITH_SALT}" -eq 1 ]]; then
  services=(sssd ssh sshd salt-minion)
else
  services=(sssd ssh sshd)
fi

for svc in "${services[@]}"; do
  log "Перезапуск сервиса: ${svc}"
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

if [[ "${WITH_SALT}" -eq 1 ]]; then
  curl -k -sS -m 10 -X POST "https://${API_HOST}/api/salt/minion" \
    -H 'accept: application/json' \
    -H "Cookie: id=${access_token}" \
    -H 'Content-Type: application/json' \
    -d "{\"id\": \"${guid}\"}" >/dev/null || true
fi

log "Настройка завершена успешно."
warn "Рекомендуется перезагрузка системы для применения всех изменений."
