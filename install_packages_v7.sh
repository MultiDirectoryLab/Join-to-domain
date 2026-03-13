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

script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Файл не найден: $path"
}

install_deb_local() {
  local path="$1"
  require_file "$path"

  log "Установка DEB: $path"

  sudo dpkg -i "$path" || true
  sudo apt-get -f install -y
}

install_rpm_local() {
  local mgr="$1"
  local path="$2"

  require_file "$path"

  log "Установка RPM: $path"

  if [[ "$mgr" == "dnf" ]]; then
    sudo dnf -y install "$path"
  else
    sudo yum -y localinstall "$path"
  fi
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
      1)
        EDITION="enterprise"
        WITH_SALT=1
        log "Выбрана редакция: Enterprise"
        return
        ;;
      2)
        EDITION="community"
        WITH_SALT=0
        log "Выбрана редакция: Community"
        return
        ;;
      *)
        warn "Введите 1 или 2."
        ;;
    esac
  done
}

# -----------------------

need_cmd sudo
need_cmd curl

SCRIPT_DIR="$(script_dir)"

prompt_edition

log "Установка пакетов из репозиториев ОС..."

if command -v apt-get >/dev/null 2>&1; then

  std_packages=(
    krb5-user
    libpam-krb5
    sssd-ldap
    sssd-krb5
    sssd
    sssd-tools
    ldap-utils
    jq
    curl
    libsss-sudo
  )

  sudo apt-get update -q
  sudo apt-get install -y "${std_packages[@]}"

  if [[ "$WITH_SALT" -eq 1 ]]; then

    install_deb_local "${SCRIPT_DIR}/deb/salt_common.deb"
    install_deb_local "${SCRIPT_DIR}/deb/salt_minion.deb"

  else
    log "Community: Salt пакеты не устанавливаются"
  fi

elif command -v dnf >/dev/null 2>&1; then

  std_packages=(
    krb5-workstation
    sssd-ldap
    sssd-krb5
    sssd
    sssd-tools
    openldap-clients
    jq
    curl
  )

  sudo dnf -y install "${std_packages[@]}"

  if [[ "$WITH_SALT" -eq 1 ]]; then

    install_rpm_local dnf "${SCRIPT_DIR}/rpm/salt_common.rpm"
    install_rpm_local dnf "${SCRIPT_DIR}/rpm/salt_minion.rpm"

  else
    log "Community: Salt пакеты не устанавливаются"
  fi

elif command -v yum >/dev/null 2>&1; then

  std_packages=(
    krb5-workstation
    sssd-ldap
    sssd-krb5
    sssd
    sssd-tools
    openldap-clients
    jq
    curl
  )

  sudo yum -y install "${std_packages[@]}"

  if [[ "$WITH_SALT" -eq 1 ]]; then

    install_rpm_local yum "${SCRIPT_DIR}/rpm/salt_common.rpm"
    install_rpm_local yum "${SCRIPT_DIR}/rpm/salt_minion.rpm"

  else
    log "Community: Salt пакеты не устанавливаются"
  fi

else

  die "Не найден менеджер пакетов (apt/dnf/yum)"

fi

log "Установка пакетов завершена"

# -----------------------
# configure question
# -----------------------

echo
echo -e "${YELLOW}Хотите выполнить конфигурацию системы сейчас?${NC}"
echo "1. Да"
echo "2. Нет"

while true; do

  echo -ne "${YELLOW}Выберите (1/2): ${NC}"
  IFS= read -r choice </dev/tty

  case "$choice" in

    1)

      CONFIG_SCRIPT="${SCRIPT_DIR}/configure_v7.sh"

      require_file "$CONFIG_SCRIPT"

      log "Запуск configure.sh"

      chmod +x "$CONFIG_SCRIPT"

      "$CONFIG_SCRIPT"

      break
      ;;

    2)

      log "Конфигурация пропущена"
      log "Скрипт завершен"

      exit 0
      ;;

    *)

      warn "Введите 1 или 2"

      ;;

  esac

done

log "Установка завершена"
