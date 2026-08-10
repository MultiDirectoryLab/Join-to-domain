load_required_packages() {
  REQUIRED_PACKAGES=()

  if ! need_script "$INSTALL_PACKAGES_SCRIPT"; then
    return 1
  fi

  mapfile -t REQUIRED_PACKAGES < <(bash "$INSTALL_PACKAGES_SCRIPT" list-required-packages)

  if [[ "${#REQUIRED_PACKAGES[@]}" -eq 0 ]]; then
    error "Installer returned an empty dependency list"
    return 1
  fi

  debug "Required packages: ${REQUIRED_PACKAGES[*]}"
  return 0
}

need_script() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    error "Required internal component not found"
    return 1
  fi

  return 0
}

package_binaries() {
  case "$1" in
    ca-certificates|libnss-sss|libpam-sss|libpam-modules|sssd-client|oddjob-mkhomedir)
      ;;
    openssl)
      printf '%s\n' openssl
      ;;
    ldap-utils|openldap-clients)
      printf '%s\n' ldapwhoami
      ;;
    curl)
      printf '%s\n' curl
      ;;
    jq)
      printf '%s\n' jq
      ;;
    file)
      printf '%s\n' file
      ;;
    sudo)
      printf '%s\n' sudo
      ;;
    krb5-user|krb5-workstation)
      printf '%s\n' kinit klist
      ;;
    sssd)
      printf '%s\n' sssd
      ;;
    sssd-tools)
      printf '%s\n' sssctl
      ;;
    oddjob)
      printf '%s\n' oddjobd
      ;;
    openssh-server)
      printf '%s\n' sshd
      ;;
    libparsec-db-sssd3|libparsec-mac-db-sssd3|libparsec-mic-db-sssd3|libparsec-aud-db-sssd3|libparsec-cap-db-sssd3|sssd-dbus)
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

is_package_installed() {
  local package="$1"

  case "$PACKAGE_DB" in
    deb)
      dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
      ;;
    rpm)
      rpm -q "$package" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

verify_package_installation() {
  local package="$1"

  if is_package_installed "$package"; then
    info "Installed: ${package}"
    return 0
  fi

  error "Package is not installed after installation attempt: ${package}"
  return 1
}

install_packages() {
  local packages=()
  local package failed=0

  if [[ "$#" -gt 0 ]]; then
    packages=("$@")
  fi

  log "INFO" "Install packages requested"

  if [[ -f "$INSTALL_PACKAGES_SCRIPT" ]]; then
    if ! need_root_for_install; then
      return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "Dry-run: run package installation"
      return 0
    fi

    info "Running package installation"
    JOIN_TO_DOMAIN_SKIP_CONFIGURE_PROMPT=1 bash "$INSTALL_PACKAGES_SCRIPT" join
    return $?
  fi

  if ! detect_package_manager; then
    return 1
  fi

  load_required_packages || return 1

  if [[ "$#" -eq 0 ]]; then
    packages=("${REQUIRED_PACKAGES[@]}")
  fi

  if ! need_root_for_install; then
    return 1
  fi

  if [[ "${#packages[@]}" -eq 0 ]]; then
    info "No packages to install"
    return 0
  fi

  case "$PACKAGE_MANAGER" in
    apt|apt-get)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: apt-get update"
        info "Dry-run: apt-get install -y ${packages[*]}"
      else
        info "Updating package index"
        if ! apt-get update; then
          error "apt-get update failed"
          return 1
        fi

        info "Installing required packages"
        if ! apt-get install -y "${packages[@]}"; then
          error "apt-get install failed"
          return 1
        fi
      fi
      ;;
    dnf|yum)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: ${PACKAGE_MANAGER} install -y ${packages[*]}"
      else
        info "Installing required packages"
        if ! "$PACKAGE_MANAGER" install -y "${packages[@]}"; then
          error "${PACKAGE_MANAGER} install failed"
          return 1
        fi
      fi
      ;;
  esac

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "Dry-run mode: package verification skipped"
    return 0
  fi

  for package in "${packages[@]}"; do
    verify_package_installation "$package" || failed=1
  done

  if [[ "$failed" -ne 0 ]]; then
    error "One or more packages failed verification"
    return 1
  fi

  info "Package installation completed"
  return 0
}

check_dependencies() {
  local package binary package_missing missing_binary_count

  MISSING_PACKAGES=()
  MISSING_BINARIES=()

  log "INFO" "Dependency check started"

  if ! detect_package_manager; then
    error "Missing required dependencies"
    return 1
  fi

  load_required_packages || return 1

  for package in "${REQUIRED_PACKAGES[@]}"; do
    package_missing=0

    if ! is_package_installed "$package"; then
      package_missing=1
    fi

    missing_binary_count=0
    while IFS= read -r binary; do
      [[ -n "$binary" ]] || continue

      if ! have_executable "$binary"; then
        MISSING_BINARIES+=("${package}: ${binary}")
        missing_binary_count=$((missing_binary_count + 1))
      fi
    done < <(package_binaries "$package")

    if [[ "$package_missing" -eq 1 ]]; then
      MISSING_PACKAGES+=("$package")
    fi
  done

  if [[ "${#MISSING_PACKAGES[@]}" -eq 0 && "${#MISSING_BINARIES[@]}" -eq 0 ]]; then
    info "All required dependencies are installed"
    return 0
  fi

  error "Missing required dependencies"
  if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
    printf '\n%s:\n' "$(ui_text "Missing packages" "Отсутствующие пакеты")"
    for package in "${MISSING_PACKAGES[@]}"; do
      printf '  - %s\n' "$package"
    done
  fi

  if [[ "${#MISSING_BINARIES[@]}" -gt 0 ]]; then
    printf '\n%s:\n' "$(ui_text "Missing commands" "Отсутствующие команды")"
    for binary in "${MISSING_BINARIES[@]}"; do
      printf '  - %s\n' "$binary"
    done
  fi

  log "ERROR" "Missing packages: ${MISSING_PACKAGES[*]}"
  log "ERROR" "Missing commands: ${MISSING_BINARIES[*]}"
  return 1
}
