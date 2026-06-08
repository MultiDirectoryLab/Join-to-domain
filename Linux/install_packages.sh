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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
DEB_DIR="${FILES_DIR}/deb"
RPM_DIR="${FILES_DIR}/rpm"
CONFIGURE_SCRIPT="${SCRIPT_DIR}/configure.sh"

MD_JOIN_ENV="/etc/MultiDirectory/state/join.env"

LOG_FILE="/var/log/multidirectory-install-packages.log"

STATE_DIR="/var/lib/MultiDirectory/install"
PKGS_BEFORE="${STATE_DIR}/packages-before.list"
PKGS_AFTER="${STATE_DIR}/packages-after.list"
PKGS_INSTALLED="${STATE_DIR}/packages-installed-by-script.list"
LOCAL_PKGS_INSTALLED="${STATE_DIR}/local-packages-installed-by-script.list"
PACKAGES_TO_REMOVE="${STATE_DIR}/packages-to-remove.list"
INSTALL_ENV="${STATE_DIR}/install.env"

usage() {
  echo "Usage: $0 {join|leave}"
  exit 1
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  exec > >(tee -a "$LOG_FILE") 2>&1

  log "Log file: ${LOG_FILE}"
  log "Script directory: ${SCRIPT_DIR}"
  log "Files directory: ${FILES_DIR}"
  log "State directory: ${STATE_DIR}"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo $0 {join|leave}"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

read_tty() {
  local var="$1"
  local prompt="$2"

  echo -ne "${YELLOW}${prompt}${NC} " > /dev/tty
  IFS= read -r "$var" < /dev/tty
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

  log "Package manager: ${PM}"
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

save_install_env() {
  init_state_dir

  cat > "$INSTALL_ENV" <<EOF2
EDITION=${EDITION}
WITH_SALT=${WITH_SALT}
EOF2

  chmod 600 "$INSTALL_ENV"
  log "Install state saved: ${INSTALL_ENV}"
}

save_packages_before() {
  init_state_dir

  log "Saving package list before installation"

  if is_deb_based || [[ "${PM:-}" == "apt-get" ]]; then
    need_cmd dpkg-query
    dpkg-query -W -f='${binary:Package}\n' | sort -u > "$PKGS_BEFORE"
  else
    need_cmd rpm
    rpm -qa --qf '%{NAME}\n' | sort -u > "$PKGS_BEFORE"
  fi

  chmod 600 "$PKGS_BEFORE"
}

save_packages_after() {
  init_state_dir

  log "Saving package list after installation"

  if is_deb_based || [[ "${PM:-}" == "apt-get" ]]; then
    need_cmd dpkg-query
    dpkg-query -W -f='${binary:Package}\n' | sort -u > "$PKGS_AFTER"
  else
    need_cmd rpm
    rpm -qa --qf '%{NAME}\n' | sort -u > "$PKGS_AFTER"
  fi

  chmod 600 "$PKGS_AFTER"
}

calculate_installed_by_script() {
  [[ -f "$PKGS_BEFORE" ]] || die "Missing package snapshot: ${PKGS_BEFORE}"
  [[ -f "$PKGS_AFTER" ]] || die "Missing package snapshot: ${PKGS_AFTER}"

  log "Calculating packages installed by this script"

  comm -13 "$PKGS_BEFORE" "$PKGS_AFTER" > "$PKGS_INSTALLED"
  chmod 600 "$PKGS_INSTALLED"

  if [[ -s "$PKGS_INSTALLED" ]]; then
    warn "Packages installed by this script:"
    sed 's/^/  - /' "$PKGS_INSTALLED"
  else
    log "No new packages were detected"
  fi
}

get_deb_package_name() {
  local deb="$1"

  if have_cmd dpkg-deb; then
    dpkg-deb -f "$deb" Package 2>/dev/null || true
  fi
}

get_deb_package_version() {
  local deb="$1"

  if have_cmd dpkg-deb; then
    dpkg-deb -f "$deb" Version 2>/dev/null || true
  fi
}

get_deb_package_status() {
  local pkg="$1"

  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true
}

get_deb_installed_version() {
  local pkg="$1"

  dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true
}

is_deb_package_installed() {
  local pkg="$1"
  [[ "$(get_deb_package_status "$pkg")" == "install ok installed" ]]
}

purge_deb_config_files_if_needed() {
  local pkg="$1"
  local status

  status="$(get_deb_package_status "$pkg")"

  case "$status" in
    "install ok installed")
      return 0
      ;;
    "")
      return 0
      ;;
    *)
      warn "Package ${pkg} is not fully installed: ${status}. Purging stale dpkg state."
      apt-get purge -y "$pkg" || true
      return 0
      ;;
  esac
}

get_rpm_package_name() {
  local rpm_file="$1"

  if have_cmd rpm; then
    rpm -qp --qf '%{NAME}\n' "$rpm_file" 2>/dev/null || true
  fi
}

get_rpm_package_version() {
  local rpm_file="$1"

  if have_cmd rpm; then
    rpm -qp --qf '%{VERSION}-%{RELEASE}\n' "$rpm_file" 2>/dev/null || true
  fi
}

track_local_package() {
  local pkg="$1"

  [[ -n "$pkg" ]] || return 0

  init_state_dir

  grep -Fxq "$pkg" "$LOCAL_PKGS_INSTALLED" 2>/dev/null || echo "$pkg" >> "$LOCAL_PKGS_INSTALLED"
}

salt_minion_unit_exists() {
  systemctl daemon-reload >/dev/null 2>&1 || true

  systemctl list-unit-files salt-minion.service 2>/dev/null | grep -q '^salt-minion\.service'
}

salt_minion_binary_exists() {
  have_cmd salt-minion
}

local_deb_packages() {
  [[ -d "$DEB_DIR" ]] || return 0

  shopt -s nullglob
  local debs=("${DEB_DIR}"/*.deb)
  shopt -u nullglob

  printf '%s\n' "${debs[@]}"
}

print_salt_diagnostics() {
  warn "Salt minion diagnostics:"

  if have_cmd dpkg-query; then
    dpkg-query -W -f='  dpkg: ${binary:Package} ${Version} ${Status}\n' 'salt*' 2>/dev/null || true
  fi

  if have_cmd rpm; then
    rpm -qa | grep -Ei '^salt|minion' | sed 's/^/  rpm: /' || true
  fi

  systemctl list-unit-files 2>/dev/null | grep -E '^salt|minion' | sed 's/^/  unit: /' || true

  if [[ -d "${DEB_DIR}" ]]; then
    shopt -s nullglob
    local debs=("${DEB_DIR}"/*.deb)
    shopt -u nullglob

    if (( ${#debs[@]} > 0 )) && have_cmd dpkg-deb; then
      warn "Systemd/binary-related files inside local DEB packages:"
      dpkg-deb -c "${debs[@]}" 2>/dev/null \
        | grep -Ei 'systemd|service|salt-minion|/usr/bin/salt|/usr/bin/salt-minion|/usr/lib/salt|/opt/salt' \
        | sed 's/^/  /' || true
    fi
  fi

  if [[ -d "${RPM_DIR}" ]] && have_cmd rpm; then
    shopt -s nullglob
    local rpms=("${RPM_DIR}"/*.rpm)
    shopt -u nullglob

    if (( ${#rpms[@]} > 0 )); then
      warn "Systemd/binary-related files inside local RPM packages:"
      for rpm_file in "${rpms[@]}"; do
        rpm -qlp "$rpm_file" 2>/dev/null \
          | grep -Ei 'systemd|service|salt-minion|/usr/bin/salt|/usr/bin/salt-minion|/usr/lib/salt|/opt/salt' \
          | sed "s#^#  ${rpm_file}: #" || true
      done
    fi
  fi
}

create_salt_minion_unit_if_possible() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || return 0

  if salt_minion_unit_exists; then
    return 0
  fi

  if ! salt_minion_binary_exists; then
    return 1
  fi

  warn "salt-minion.service is missing, but salt-minion binary exists. Creating compatibility systemd unit."

  cat > /etc/systemd/system/salt-minion.service <<'EOF2'
[Unit]
Description=The Salt Minion
Documentation=man:salt-minion(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/salt-minion
Restart=on-failure
RestartSec=5s
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 /etc/systemd/system/salt-minion.service
  systemctl daemon-reload || true

  salt_minion_unit_exists
}

require_salt_minion_installed() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || return 0

  if ! salt_minion_binary_exists; then
    print_salt_diagnostics
    die "salt-minion command not found after package installation. Local DEB/RPM package does not install the minion binary or dependencies failed."
  fi

  if ! salt_minion_unit_exists; then
    create_salt_minion_unit_if_possible || true
  fi

  if ! salt_minion_unit_exists; then
    print_salt_diagnostics
    die "salt-minion.service not found after package installation"
  fi

  log "Salt minion binary and systemd unit are present"
}

install_local_deb_packages() {
  if [[ "${WITH_SALT}" -ne 1 ]]; then
    log "Community edition: local DEB packages from ${DEB_DIR} are skipped"
    return 0
  fi

  if [[ ! -d "${DEB_DIR}" ]]; then
    warn "Directory not found: ${DEB_DIR}"
    return 0
  fi

  need_cmd dpkg-deb
  need_cmd dpkg-query

  shopt -s nullglob
  local debs=("${DEB_DIR}"/*.deb)
  shopt -u nullglob

  if (( ${#debs[@]} == 0 )); then
    warn "No local .deb packages found in ${DEB_DIR}"
    return 0
  fi

  log "Enterprise edition: checking local DEB packages from ${DEB_DIR}"

  local deb pkg deb_version installed_version installed_status
  local debs_to_install=()
  local local_pkg_names=()

  for deb in "${debs[@]}"; do
    pkg="$(get_deb_package_name "$deb")"
    deb_version="$(get_deb_package_version "$deb")"

    if [[ -z "$pkg" ]]; then
      warn "Cannot detect package name for ${deb}, skipping"
      continue
    fi

    track_local_package "$pkg"
    local_pkg_names+=("$pkg")

    purge_deb_config_files_if_needed "$pkg"

    installed_status="$(get_deb_package_status "$pkg")"
    installed_version="$(get_deb_installed_version "$pkg")"

    if [[ "$installed_status" == "install ok installed" && -n "$installed_version" && -n "$deb_version" && "$installed_version" == "$deb_version" ]]; then
      if [[ "$pkg" == "salt-minion" ]] && ! salt_minion_unit_exists; then
        warn "Package ${pkg} ${installed_version} is installed, but salt-minion.service is missing; will reinstall"
      elif [[ "$pkg" == "salt-minion" ]] && ! salt_minion_binary_exists; then
        warn "Package ${pkg} ${installed_version} is installed, but salt-minion binary is missing; will reinstall"
      else
        log "Local package already installed with same version, skipping: ${pkg} ${installed_version}"
        continue
      fi
    fi

    if [[ "$installed_status" == "install ok installed" ]]; then
      warn "Local package ${pkg} installed version ${installed_version:-unknown}, local version ${deb_version:-unknown}; will install/update"
    else
      log "Local package is not installed yet or was purged: ${pkg}"
    fi

    debs_to_install+=("$deb")
  done

  if (( ${#debs_to_install[@]} == 0 )); then
    log "No local DEB packages need installation"
    return 0
  fi

  log "Installing local DEB packages via apt-get:"
  printf '  - %s\n' "${debs_to_install[@]}"

  if ! apt-get install -y "${debs_to_install[@]}"; then
    print_salt_diagnostics
    die "Failed to install local DEB packages via apt-get"
  fi

  systemctl daemon-reload || true

  local failed=0
  for pkg in "${local_pkg_names[@]}"; do
    if ! is_deb_package_installed "$pkg"; then
      warn "Local package is not fully installed after apt-get install: ${pkg} ($(get_deb_package_status "$pkg"))"
      failed=1
    fi
  done

  if (( failed != 0 )); then
    print_salt_diagnostics
    die "One or more local DEB packages are not fully installed"
  fi

  if [[ "${WITH_SALT}" -eq 1 ]]; then
    require_salt_minion_installed
  fi
}

install_local_rpm_packages() {
  if [[ "${WITH_SALT}" -ne 1 ]]; then
    log "Community edition: local RPM packages from ${RPM_DIR} are skipped"
    return 0
  fi

  if [[ ! -d "${RPM_DIR}" ]]; then
    warn "Directory not found: ${RPM_DIR}"
    return 0
  fi

  shopt -s nullglob
  local rpms=("${RPM_DIR}"/*.rpm)
  shopt -u nullglob

  if (( ${#rpms[@]} == 0 )); then
    warn "No local .rpm packages found in ${RPM_DIR}"
    return 0
  fi

  log "Enterprise edition: checking local RPM packages from ${RPM_DIR}"

  local rpm_file pkg rpm_version installed_version
  local rpms_to_install=()

  for rpm_file in "${rpms[@]}"; do
    pkg="$(get_rpm_package_name "$rpm_file")"
    rpm_version="$(get_rpm_package_version "$rpm_file")"

    if [[ -z "$pkg" ]]; then
      warn "Cannot detect package name for ${rpm_file}, skipping"
      continue
    fi

    track_local_package "$pkg"

    installed_version="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null || true)"

    if [[ -n "$installed_version" && "$installed_version" != *"not installed"* && "$installed_version" == "$rpm_version" ]]; then
      if [[ "$pkg" == "salt-minion" ]] && ! salt_minion_unit_exists; then
        warn "Package ${pkg} ${installed_version} is installed, but salt-minion.service is missing; will reinstall"
      else
        log "Local package already installed with same version, skipping: ${pkg} ${installed_version}"
        continue
      fi
    fi

    if [[ -n "$installed_version" && "$installed_version" != *"not installed"* ]]; then
      warn "Local package ${pkg} installed version ${installed_version}, local version ${rpm_version:-unknown}; will install/update"
    else
      log "Local package is not installed yet: ${pkg}"
    fi

    rpms_to_install+=("$rpm_file")
  done

  if (( ${#rpms_to_install[@]} == 0 )); then
    log "No local RPM packages need installation"
    return 0
  fi

  log "Installing local RPM packages:"
  printf '  - %s\n' "${rpms_to_install[@]}"

  if [[ "${PM}" == "apt-get" ]]; then
    apt-get install -y "${rpms_to_install[@]}" || rpm -Uvh --replacepkgs "${rpms_to_install[@]}"
  else
    "${PM}" install -y "${rpms_to_install[@]}" || rpm -Uvh --replacepkgs "${rpms_to_install[@]}"
  fi

  systemctl daemon-reload || true

  if [[ "${WITH_SALT}" -eq 1 ]]; then
    require_salt_minion_installed
  fi
}

install_deb_packages() {
  log "Detected DEB-based system: ${OS_NAME}"

  apt-get update

  apt-get install -y \
    ca-certificates \
    curl \
    jq \
    file \
    sudo \
    krb5-user \
    sssd \
    sssd-tools \
    libnss-sss \
    libpam-sss \
    libpam-mkhomedir \
    oddjob \
    oddjob-mkhomedir \
    openssh-server

  install_local_deb_packages
}

install_rpm_packages() {
  log "Detected RPM-based system: ${OS_NAME}"

  detect_package_manager

  if [[ "${PM}" == "apt-get" ]]; then
    apt-get update || true

    apt-get install -y \
      ca-certificates \
      curl \
      jq \
      file \
      sudo \
      krb5-workstation \
      sssd \
      sssd-tools \
      openssh-server
  else
    "${PM}" install -y \
      ca-certificates \
      curl \
      jq \
      file \
      sudo \
      krb5-workstation \
      sssd \
      sssd-tools \
      sssd-client \
      oddjob \
      oddjob-mkhomedir \
      openssh-server

    "${PM}" install -y authselect || warn "Optional package authselect was not installed"
  fi

  install_local_rpm_packages
}

is_removable_domain_package() {
  local pkg="$1"

  case "$pkg" in
    sssd|sssd-tools|sssd-client|sssd-dbus|libnss-sss|libpam-sss|libpam-mkhomedir|oddjob|oddjob-mkhomedir)
      return 0
      ;;
    krb5-user|krb5-workstation)
      return 0
      ;;
    salt|salt-common|salt-minion)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_protected_system_package() {
  local pkg="$1"

  case "$pkg" in
    sudo|openssh-server|ssh|curl|jq|file|ca-certificates)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_removal_list() {
  local pkg

  : > "$PACKAGES_TO_REMOVE"
  chmod 600 "$PACKAGES_TO_REMOVE"

  if [[ -f "$PKGS_INSTALLED" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue

      if is_protected_system_package "$pkg"; then
        warn "Keeping protected package: ${pkg}"
        continue
      fi

      if is_removable_domain_package "$pkg"; then
        echo "$pkg" >> "$PACKAGES_TO_REMOVE"
      else
        warn "Keeping non-domain package: ${pkg}"
      fi
    done < "$PKGS_INSTALLED"
  else
    warn "Package diff manifest not found: ${PKGS_INSTALLED}"
  fi

  if [[ -f "$LOCAL_PKGS_INSTALLED" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue

      if is_protected_system_package "$pkg"; then
        warn "Keeping protected local package: ${pkg}"
        continue
      fi

      if is_removable_domain_package "$pkg"; then
        echo "$pkg" >> "$PACKAGES_TO_REMOVE"
      else
        warn "Keeping local package outside allowlist: ${pkg}"
      fi
    done < "$LOCAL_PKGS_INSTALLED"
  fi

  sort -u "$PACKAGES_TO_REMOVE" -o "$PACKAGES_TO_REMOVE"
}

remove_packages_deb() {
  mapfile -t packages < "$PACKAGES_TO_REMOVE"

  if (( ${#packages[@]} == 0 )); then
    log "No packages to remove"
    return 0
  fi

  warn "Packages to purge:"
  printf '  - %s\n' "${packages[@]}"

  apt-get purge -y "${packages[@]}"
  apt-get autoremove --purge -y
}

remove_packages_rpm() {
  mapfile -t packages < "$PACKAGES_TO_REMOVE"

  if (( ${#packages[@]} == 0 )); then
    log "No packages to remove"
    return 0
  fi

  warn "Packages to remove:"
  printf '  - %s\n' "${packages[@]}"

  detect_package_manager

  if [[ "${PM}" == "dnf" ]]; then
    dnf remove -y "${packages[@]}"
    dnf autoremove -y || true
  elif [[ "${PM}" == "yum" ]]; then
    yum remove -y "${packages[@]}"
    yum autoremove -y || true
  elif [[ "${PM}" == "apt-get" ]]; then
    apt-get purge -y "${packages[@]}"
    apt-get autoremove --purge -y
  else
    die "No supported package manager found"
  fi
}

prompt_run_configure() {
  local choice

  [[ -f "$CONFIGURE_SCRIPT" ]] || {
    warn "configure.sh not found: ${CONFIGURE_SCRIPT}"
    return 0
  }

  tty_echo ""
  tty_echo "${YELLOW}Run configuration now?${NC}"
  tty_echo "1. Yes"
  tty_echo "2. No"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"

    case "$choice" in
      1)
        log "Running configure.sh join via install_packages.sh"
        MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" join < /dev/tty
        return 0
        ;;
      2)
        log "Configuration skipped"
        log "You can run it later only through: sudo ${SCRIPT_DIR}/install_packages.sh join"
        return 0
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

run_configure_leave_if_needed() {
  if [[ -f "$MD_JOIN_ENV" ]]; then
    [[ -f "$CONFIGURE_SCRIPT" ]] || die "configure.sh not found: ${CONFIGURE_SCRIPT}"

    warn "Local domain join state found: ${MD_JOIN_ENV}"
    warn "Running configure.sh leave before package rollback"

    MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" leave < /dev/tty

    log "configure.sh leave completed"
  else
    warn "Join state file not found: ${MD_JOIN_ENV}"
    warn "Skipping configure.sh leave and running package rollback only"
  fi
}

join_packages() {
  [[ -d "${FILES_DIR}" ]] || die "Directory not found: ${FILES_DIR}"

  normalize_files_eol
  detect_package_manager

  prompt_edition
  save_install_env

  save_packages_before

  if is_deb_based; then
    install_deb_packages
  elif is_rpm_based; then
    install_rpm_packages
  else
    die "Unsupported OS: ${OS_NAME}"
  fi

  save_packages_after
  calculate_installed_by_script

  systemctl daemon-reload || true
  require_salt_minion_installed

  log "Packages installation completed"

  prompt_run_configure
}

leave_packages() {
  init_state_dir
  detect_package_manager

  warn "Leave mode selected"
  warn "Only packages installed by this script and included in the domain allowlist will be removed"
  warn "Protected system packages will not be removed"

  run_configure_leave_if_needed

  build_removal_list

  if [[ -s "$PACKAGES_TO_REMOVE" ]]; then
    log "Removal list:"
    sed 's/^/  - /' "$PACKAGES_TO_REMOVE"
  else
    log "Removal list is empty"
  fi

  if is_deb_based || [[ "${PM}" == "apt-get" ]]; then
    remove_packages_deb
  elif is_rpm_based; then
    remove_packages_rpm
  else
    die "Unsupported OS: ${OS_NAME}"
  fi

  systemctl daemon-reload || true

  log "Package rollback completed"
}

preflight() {
  need_root
  setup_logging
  load_os_release

  need_cmd file
  need_cmd sed
  need_cmd sort
  need_cmd comm
  need_cmd tee
}

main() {
  case "${1:-}" in
    join|leave)
      ;;
    *)
      usage
      ;;
  esac

  preflight

  case "$1" in
    join)
      join_packages
      ;;
    leave)
      leave_packages
      ;;
  esac
}

main "$@"
