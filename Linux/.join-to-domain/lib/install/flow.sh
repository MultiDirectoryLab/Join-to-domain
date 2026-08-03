prompt_run_configure() {
  local choice

  if [[ "${JOIN_TO_DOMAIN_SKIP_CONFIGURE_PROMPT:-0}" == "1" ]]; then
    log "Configuration prompt skipped"
    log "Run configuration later through: sudo ${PUBLIC_LAUNCHER}"
    return 0
  fi

  [[ -f "$CONFIGURE_SCRIPT" ]] || {
    warn "$(ui_text "Required internal component not found" "Не найден необходимый внутренний компонент")"
    return 0
  }

  tty_echo ""
  tty_echo "${YELLOW}$(ui_text "Run configuration now?" "Запустить настройку сейчас?")${NC}"
  tty_echo "1. $(ui_text "Yes" "Да")"
  tty_echo "2. $(ui_text "No" "Нет")"

  while true; do
    read_tty choice "$(ui_text "Select (1/2) [1]:" "Выберите (1/2) [1]:")"
    choice="${choice:-1}"

    case "$choice" in
      1)
        log "Running domain configuration"
        MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" join < /dev/tty
        return 0
        ;;
      2)
        log "$(ui_text "Configuration skipped" "Настройка пропущена")"
        log "$(ui_text "You can run it later through: sudo ${PUBLIC_LAUNCHER}" "Её можно запустить позже командой: sudo ${PUBLIC_LAUNCHER}")"
        return 0
        ;;
      *)
        warn "$(ui_text "Enter 1 or 2." "Введите 1 или 2.")"
        ;;
    esac
  done
}

run_configure_leave_if_needed() {
  if [[ -f "$MD_JOIN_ENV" ]]; then
    [[ -f "$CONFIGURE_SCRIPT" ]] || die "Required internal component not found"

    warn "Local domain join state found: ${MD_JOIN_ENV}"
    warn "Running domain cleanup before package rollback"

    MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" leave < /dev/tty

    log "Domain cleanup completed"
  else
    warn "Join state file not found: ${MD_JOIN_ENV}"
    warn "Skipping domain cleanup and running package rollback only"
  fi
}

join_packages() {
  [[ -d "${FILES_DIR}" ]] || die "Required internal package files not found"

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
    join|leave|list-required-packages)
      ;;
    *)
      usage
      ;;
  esac

  if [[ "$1" == "list-required-packages" ]]; then
    list_required_packages
    exit 0
  fi

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
