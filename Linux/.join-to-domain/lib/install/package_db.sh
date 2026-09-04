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
      apt-get purge -y "$pkg" >> "$LOG_FILE" 2>&1 || true
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
  test -f /lib/systemd/system/salt-minion.service || test -f /etc/systemd/system/salt-minion.service
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
          | sed "s#^#  $(basename "$rpm_file"): #" || true
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

}
