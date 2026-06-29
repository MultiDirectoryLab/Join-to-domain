install_deb_packages() {
  log "Detected DEB-based system: ${OS_NAME}"

  apt-get update

  apt-get install -y "${DEB_REQUIRED_PACKAGES[@]}"

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

