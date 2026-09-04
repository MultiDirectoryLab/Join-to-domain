install_local_deb_packages() {
  if [[ "${WITH_SALT}" -ne 1 ]]; then
    log "Community edition: local DEB packages are skipped"
    return 0
  fi

  if [[ ! -d "${DEB_DIR}" ]]; then
    warn "Local DEB package directory not found"
    return 0
  fi

  need_cmd dpkg-deb
  need_cmd dpkg-query

  shopt -s nullglob
  local debs=("${DEB_DIR}"/*.deb)
  shopt -u nullglob

  if (( ${#debs[@]} == 0 )); then
    warn "No local DEB packages found"
    return 0
  fi

  log "Enterprise edition: checking local DEB packages"

  local deb pkg deb_version installed_version installed_status
  local debs_to_install=()
  local local_pkg_names=()

  for deb in "${debs[@]}"; do
    pkg="$(get_deb_package_name "$deb")"
    deb_version="$(get_deb_package_version "$deb")"

    if [[ -z "$pkg" ]]; then
      warn "Cannot detect package name for $(basename "$deb"), skipping"
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
  local deb_install_args=()
  for deb in "${debs_to_install[@]}"; do
    printf '  - %s\n' "$(basename "$deb")" >> "$LOG_FILE"
    deb_install_args+=("./$(basename "$deb")")
  done

  if ! (cd "$DEB_DIR" && apt-get install -y "${deb_install_args[@]}" >> "$LOG_FILE" 2>&1); then
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
    log "Community edition: local RPM packages are skipped"
    return 0
  fi

  if [[ ! -d "${RPM_DIR}" ]]; then
    warn "Local RPM package directory not found"
    return 0
  fi

  shopt -s nullglob
  local rpms=("${RPM_DIR}"/*.rpm)
  shopt -u nullglob

  if (( ${#rpms[@]} == 0 )); then
    warn "No local RPM packages found"
    return 0
  fi

  log "Enterprise edition: checking local RPM packages"

  local rpm_file pkg rpm_version installed_version
  local rpms_to_install=()

  for rpm_file in "${rpms[@]}"; do
    pkg="$(get_rpm_package_name "$rpm_file")"
    rpm_version="$(get_rpm_package_version "$rpm_file")"

    if [[ -z "$pkg" ]]; then
      warn "Cannot detect package name for $(basename "$rpm_file"), skipping"
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
  local rpm_install_args=()
  for rpm_file in "${rpms_to_install[@]}"; do
    printf '  - %s\n' "$(basename "$rpm_file")" >> "$LOG_FILE"
    rpm_install_args+=("./$(basename "$rpm_file")")
  done

  if [[ "${PM}" == "apt-get" ]]; then
    (cd "$RPM_DIR" && apt-get install -y "${rpm_install_args[@]}" >> "$LOG_FILE" 2>&1) \
      || (cd "$RPM_DIR" && rpm -Uvh --replacepkgs "${rpm_install_args[@]}" >> "$LOG_FILE" 2>&1)
  else
    (cd "$RPM_DIR" && "${PM}" install -y "${rpm_install_args[@]}" >> "$LOG_FILE" 2>&1) \
      || (cd "$RPM_DIR" && rpm -Uvh --replacepkgs "${rpm_install_args[@]}" >> "$LOG_FILE" 2>&1)
  fi

  systemctl daemon-reload || true

  if [[ "${WITH_SALT}" -eq 1 ]]; then
    require_salt_minion_installed
  fi
}
