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

if [[ "$EUID" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Not found: $1"; }

ACTION="${1:-install}"
NO_CONFIGURE=0

for arg in "${@:2}"; do
  case "$arg" in
    --no-configure) NO_CONFIGURE=1 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_DIR="/var/lib/MULTIDIRECTORY"
PKG_MANIFEST="${STATE_DIR}/packages-installed"

read_tty() {
  local var="$1"
  local prompt="$2"
  echo -e "${YELLOW}${prompt}${NC}"
  IFS= read -r "$var" </dev/tty
  eval "$var=\$(echo \"\${$var}\" | tr -d '\r' | xargs)"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "File not found: $path"
}

is_altlinux() {
  grep -qi "altlinux" /etc/os-release 2>/dev/null
}

pkg_installed_deb() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_installed_rpm() {
  rpm -q "$1" >/dev/null 2>&1
}

remember_package() {
  local pkg="$1"

  "${SUDO[@]}" mkdir -p "$STATE_DIR"
  "${SUDO[@]}" touch "$PKG_MANIFEST"
  "${SUDO[@]}" chmod 600 "$PKG_MANIFEST"

  grep -Fxq "$pkg" "$PKG_MANIFEST" 2>/dev/null || echo "$pkg" | "${SUDO[@]}" tee -a "$PKG_MANIFEST" >/dev/null
}

install_apt_packages() {
  local pkgs=("$@")
  local to_install=()

  for pkg in "${pkgs[@]}"; do
    if ! pkg_installed_deb "$pkg"; then
      to_install+=("$pkg")
      remember_package "$pkg"
    fi
  done

  if [[ "${#to_install[@]}" -gt 0 ]]; then
    "${SUDO[@]}" apt-get update -q
    if is_altlinux; then
      "${SUDO[@]}" apt-get install -y "${to_install[@]}"
    else
      "${SUDO[@]}" apt-get install -y --no-install-recommends "${to_install[@]}"
    fi
  else
    log "All repository packages are already installed."
  fi
}

install_deb_local() {
  local path="$1"
  local pkg

  require_file "$path"

  pkg="$(dpkg-deb -f "$path" Package 2>/dev/null || true)"
  [[ -n "$pkg" ]] || die "Cannot read package name from DEB: $path"

  if ! pkg_installed_deb "$pkg"; then
    remember_package "$pkg"
    log "Installing DEB: $path"
    "${SUDO[@]}" apt-get install -y "$path"
  else
    log "Already installed: $pkg"
  fi
}

install_rpm_local() {
  local mgr="$1"
  local path="$2"
  local pkg

  require_file "$path"

  pkg="$(rpm -qp --queryformat '%{NAME}\n' "$path" 2>/dev/null || true)"
  [[ -n "$pkg" ]] || die "Cannot read package name from RPM: $path"

  if ! pkg_installed_rpm "$pkg"; then
    remember_package "$pkg"
    log "Installing RPM: $path"

    case "$mgr" in
      dnf) "${SUDO[@]}" dnf -y install "$path" ;;
      yum) "${SUDO[@]}" yum -y localinstall "$path" ;;
      alt) "${SUDO[@]}" apt-get install -y "$path" ;;
      *) die "Unknown RPM installer mode: $mgr" ;;
    esac
  else
    log "Already installed: $pkg"
  fi
}

prompt_edition() {
  echo -e "${YELLOW}Select MULTIDIRECTORY edition:${NC}"
  echo "1. Enterprise"
  echo "2. Community"

  local choice

  while true; do
    read_tty choice "Select (1/2):"
    case "$choice" in
      1) EDITION="enterprise"; WITH_SALT=1; log "Selected edition: Enterprise"; return ;;
      2) EDITION="community";  WITH_SALT=0; log "Selected edition: Community";  return ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    if is_altlinux; then
      PKG_MGR="alt"
    else
      PKG_MGR="apt"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    die "No package manager found: apt-get/dnf/yum"
  fi
}

check_salt_files_for_enterprise() {
  [[ "${WITH_SALT}" -eq 1 ]] || return 0

  case "$PKG_MGR" in
    apt)
      require_file "${SCRIPT_DIR}/files/deb/salt_common.deb"
      require_file "${SCRIPT_DIR}/files/deb/salt_minion.deb"
      ;;
    alt|dnf|yum)
      require_file "${SCRIPT_DIR}/files/rpm/salt_common.rpm"
      require_file "${SCRIPT_DIR}/files/rpm/salt_minion.rpm"
      ;;
  esac
}

install_packages() {
  if [[ "$EUID" -ne 0 ]]; then
    "${SUDO[@]}" -v || die "sudo authentication failed"
  fi

  detect_package_manager
  prompt_edition
  check_salt_files_for_enterprise

  log "Installing packages from OS repositories..."

  case "$PKG_MGR" in
    alt)
      std_packages=(
        krb5-kinit
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

      install_apt_packages "${std_packages[@]}"
      if [[ "$WITH_SALT" -eq 1 ]]; then
        install_rpm_local alt "${SCRIPT_DIR}/files/rpm/salt_common.rpm"
        install_rpm_local alt "${SCRIPT_DIR}/files/rpm/salt_minion.rpm"
      else
        log "Community: Salt packages are not installed."
      fi
      ;;

    apt)
      std_packages=(
        krb5-user
        sssd
        sssd-tools
        sssd-ldap
        sssd-krb5
        libpam-sss
        libnss-sss
        libsss-sudo
        ldap-utils
        jq
        curl
      )

      install_apt_packages "${std_packages[@]}"
      if [[ "$WITH_SALT" -eq 1 ]]; then
        install_deb_local "${SCRIPT_DIR}/files/deb/salt_common.deb"
        install_deb_local "${SCRIPT_DIR}/files/deb/salt_minion.deb"
      else
        log "Community: Salt packages are not installed."
      fi
      ;;

    dnf)
      std_packages=(
        krb5-workstation
        sssd
        sssd-tools
        sssd-ldap
        sssd-krb5
        openldap-clients
        jq
        curl
      )

      for pkg in "${std_packages[@]}"; do
        if ! pkg_installed_rpm "$pkg"; then
          remember_package "$pkg"
        fi
      done
      "${SUDO[@]}" dnf -y install "${std_packages[@]}"
      if [[ "$WITH_SALT" -eq 1 ]]; then
        install_rpm_local dnf "${SCRIPT_DIR}/files/rpm/salt_common.rpm"
        install_rpm_local dnf "${SCRIPT_DIR}/files/rpm/salt_minion.rpm"
      else
        log "Community: Salt packages are not installed."
      fi
      ;;
    yum)
      std_packages=(
        krb5-workstation
        sssd
        sssd-tools
        sssd-ldap
        sssd-krb5
        openldap-clients
        jq
        curl
      )

      for pkg in "${std_packages[@]}"; do
        if ! pkg_installed_rpm "$pkg"; then
          remember_package "$pkg"
        fi
      done
      "${SUDO[@]}" yum -y install "${std_packages[@]}"
      if [[ "$WITH_SALT" -eq 1 ]]; then
        install_rpm_local yum "${SCRIPT_DIR}/files/rpm/salt_common.rpm"
        install_rpm_local yum "${SCRIPT_DIR}/files/rpm/salt_minion.rpm"
      else
        log "Community: Salt packages are not installed."
      fi
      ;;
  esac

  log "Package installation completed."
  if [[ "$NO_CONFIGURE" -eq 1 ]]; then
    log "Configuration skipped by --no-configure."
    log "To configure later, run: bash ${SCRIPT_DIR}/configure.sh join"
    return 0
  fi

  echo
  echo -e "${YELLOW}Do you want to configure the system now?${NC}"
  echo "1. Yes"
  echo "2. No"

  local choice
  while true; do
    read_tty choice "Select (1/2):"
    case "$choice" in
      1)
        CONFIG_SCRIPT="${SCRIPT_DIR}/configure.sh"
        require_file "$CONFIG_SCRIPT"
        log "Starting configure.sh join"
        bash "$CONFIG_SCRIPT" join
        break
        ;;
      2)
        log "Configuration skipped."
        log "To configure later, run: bash ${SCRIPT_DIR}/configure.sh join"
        break
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
  log "Installation completed."
}

remove_packages() {
  if [[ "$EUID" -ne 0 ]]; then
    "${SUDO[@]}" -v || die "sudo authentication failed"
  fi

  CONFIG_SCRIPT="${SCRIPT_DIR}/configure.sh"
  if [[ -f "$CONFIG_SCRIPT" ]]; then
    warn "Running domain leave before package removal..."
    if ! bash "$CONFIG_SCRIPT" leave; then
      warn "Domain leave failed. Aborting package removal."
      return 1
    fi
  else
    warn "configure.sh not found, domain leave skipped."
  fi

  if [[ -d /etc/salt ]]; then
    log "Cleaning /etc/salt directory..."
    "${SUDO[@]}" rm -rf /etc/salt
    log "/etc/salt removed."
  else
    log "/etc/salt not found, skipping."
  fi

  if [[ ! -f "$PKG_MANIFEST" ]]; then
    warn "Package manifest not found: $PKG_MANIFEST"
    warn "Nothing will be removed automatically."
    return 0
  fi

  mapfile -t packages < "$PKG_MANIFEST"
  if [[ "${#packages[@]}" -eq 0 ]]; then
    warn "Package manifest is empty."
    return 0
  fi

  log "Packages installed by this script:"
  printf '  - %s\n' "${packages[@]}"
  echo
  echo -e "${YELLOW}Remove these packages?${NC}"
  echo "1. Yes"
  echo "2. No"

  local choice
  while true; do
    read_tty choice "Select (1/2):"
    case "$choice" in
      1) break ;;
      2) log "Package removal cancelled."; return 0 ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done

  detect_package_manager

  KEEP=(curl jq openldap-clients ldap-utils task-auth-ad-sssd)
  safe_packages=()
  for p in "${packages[@]}"; do
    skip=0
    for k in "${KEEP[@]}"; do
      [[ "$p" == "$k" ]] && { skip=1; break; }
    done
    [[ "$skip" -eq 0 ]] && safe_packages+=("$p")
  done

  if [[ "${#safe_packages[@]}" -eq 0 ]]; then
    warn "Nothing safe to remove (all tracked packages are system-shared)."
    "${SUDO[@]}" rm -f "$PKG_MANIFEST"
    log "Package removal completed."
    return 0
  fi

  log "Removing client packages: ${safe_packages[*]}"

  case "$PKG_MGR" in
    apt|alt)
      "${SUDO[@]}" apt-get remove -y "${safe_packages[@]}" || true
      ;;
    dnf)
      "${SUDO[@]}" dnf -y remove "${safe_packages[@]}" || true
      ;;
    yum)
      "${SUDO[@]}" yum -y remove "${safe_packages[@]}" || true
      ;;
  esac

  "${SUDO[@]}" rm -f "$PKG_MANIFEST"

  log "Package removal completed."
}

case "$ACTION" in
  install)
    install_packages
    ;;
  remove)
    remove_packages
    ;;
  *)
    die "Usage: $0 [install|remove] [--no-configure]"
    ;;
esac