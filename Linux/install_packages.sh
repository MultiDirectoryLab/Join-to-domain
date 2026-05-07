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

script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "File not found: $path"
}

install_deb_local() {
  local path="$1"
  require_file "$path"

  log "Installing DEB: $path"

  sudo dpkg -i "$path" || true
  sudo apt-get -f install -y
}

install_rpm_local() {
  local mgr="$1"
  local path="$2"

  require_file "$path"

  log "Installing RPM: $path"

  if [[ "$mgr" == "dnf" ]]; then
    sudo dnf -y install "$path"
  elif [[ "$mgr" == "yum" ]]; then
    sudo yum -y localinstall "$path"
  else
    # ALT Linux or fallback
    sudo rpm -i "$path" || true
    sudo apt-get -f install -y
  fi
}

is_altlinux() {
  grep -qi "altlinux" /etc/os-release 2>/dev/null
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
      1)
        EDITION="enterprise"
        WITH_SALT=1
        log "Selected edition: Enterprise"
        return
        ;;
      2)
        EDITION="community"
        WITH_SALT=0
        log "Selected edition: Community"
        return
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

# -----------------------

need_cmd sudo
need_cmd curl

SCRIPT_DIR="$(script_dir)"

prompt_edition

log "Installing packages from OS repositories..."

if command -v apt-get >/dev/null 2>&1; then

  if is_altlinux; then
    # ---------- ALT Linux (apt-rpm) ----------
    std_packages=(
      krb5-kinit
      pam_krb5
      task-auth-ad-sssd
      sssd
      sssd-client
      sssd-ldap
      sssd-krb5
      sssd-tools
      openldap-clients
      jq
      curl
      libsss_sudo
    )

    sudo apt-get update -q
    sudo apt-get install -y "${std_packages[@]}"

    if [[ "$WITH_SALT" -eq 1 ]]; then
      # On ALT, use RPM packages from the rpm directory
      install_rpm_local alt "${SCRIPT_DIR}/rpm/salt_common.rpm"
      install_rpm_local alt "${SCRIPT_DIR}/rpm/salt_minion.rpm"
    else
      log "Community: Salt packages are not installed"
    fi

  else
    # ---------- Debian/Ubuntu ----------
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
      log "Community: Salt packages are not installed"
    fi
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
    log "Community: Salt packages are not installed"
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
    log "Community: Salt packages are not installed"
  fi

else

  die "No package manager found (apt/dnf/yum)"

fi

log "Package installation completed"

# -----------------------
# configure question
# -----------------------

echo
echo -e "${YELLOW}Do you want to configure the system now?${NC}"
echo "1. Yes"
echo "2. No"

while true; do

  echo -ne "${YELLOW}Select (1/2): ${NC}"
  IFS= read -r choice </dev/tty

  case "$choice" in

    1)

      CONFIG_SCRIPT="${SCRIPT_DIR}/configure.sh"

      require_file "$CONFIG_SCRIPT"

      log "Starting configure.sh"

      chmod +x "$CONFIG_SCRIPT"

      "$CONFIG_SCRIPT"

      break
      ;;

    2)

      log "Configuration skipped"
      log "Script completed"

      exit 0
      ;;

    *)

      warn "Enter 1 or 2"

      ;;

  esac

done

log "Installation completed"
