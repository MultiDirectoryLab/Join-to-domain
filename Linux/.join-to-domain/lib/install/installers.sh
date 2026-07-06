install_deb_packages() {
  local packages=("${DEB_REQUIRED_PACKAGES[@]}")

  log "Detected DEB-based system: ${OS_NAME}"

  apt-get update

  if is_astra_se; then
    packages+=(
      libparsec-db-sssd3
      libparsec-mac-db-sssd3
      libparsec-mic-db-sssd3
      libparsec-aud-db-sssd3
      libparsec-cap-db-sssd3
      sssd-dbus
    )
  fi

  apt-get install -y "${packages[@]}"

  install_local_deb_packages
}

install_rpm_packages() {
  log "Detected RPM-based system: ${OS_NAME}"

  detect_package_manager

  if [[ "${PM}" == "apt-get" ]]; then
    apt-get update || true

    apt-get install -y "${RPM_APT_REQUIRED_PACKAGES[@]}"
  else
    "${PM}" install -y "${RPM_REQUIRED_PACKAGES[@]}"

    "${PM}" install -y authselect || warn "Optional package authselect was not installed"
  fi

  install_local_rpm_packages
}

list_required_packages() {
  LIST_REQUIRED_PACKAGES_MODE=1

  load_os_release
  detect_package_manager

  if is_deb_based; then
    if is_astra_se; then
      printf '%s\n' \
        "${DEB_REQUIRED_PACKAGES[@]}" \
        libparsec-db-sssd3 \
        libparsec-mac-db-sssd3 \
        libparsec-mic-db-sssd3 \
        libparsec-aud-db-sssd3 \
        libparsec-cap-db-sssd3 \
        sssd-dbus
      return 0
    fi

    printf '%s\n' "${DEB_REQUIRED_PACKAGES[@]}"
  elif is_rpm_based; then
    if [[ "${PM}" == "apt-get" ]]; then
      printf '%s\n' "${RPM_APT_REQUIRED_PACKAGES[@]}"
    else
      printf '%s\n' "${RPM_REQUIRED_PACKAGES[@]}"
    fi
  else
    die "Unsupported OS: ${OS_NAME}"
  fi
}
