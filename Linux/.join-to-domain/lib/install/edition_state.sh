prompt_edition() {
  local choice

  if use_env_edition_if_available; then
    return 0
  fi

  tty_echo "${YELLOW}$(ui_text "Select MultiDirectory edition:" "Выберите редакцию MultiDirectory:")${NC}"
  tty_echo "1. Enterprise"
  tty_echo "2. Community"

  while true; do
    read_tty choice "$(ui_text "Select (1/2) [1]:" "Выберите (1/2) [1]:")"
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
        warn "$(ui_text "Enter 1 or 2." "Введите 1 или 2.")"
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

  if is_altlinux || is_rpm_based; then
    need_cmd rpm
    rpm -qa --qf '%{NAME}\n' | sort -u > "$PKGS_BEFORE"
  elif is_deb_based; then
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

  if is_altlinux || is_rpm_based; then
    need_cmd rpm
    rpm -qa --qf '%{NAME}\n' | sort -u > "$PKGS_AFTER"
  elif is_deb_based; then
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
