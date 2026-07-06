configure_domain() {
  log "INFO" "Domain configuration requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Domain configuration requires root. Run: sudo $0"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: run domain configuration"
    return 0
  fi

  info "Running domain configuration"
  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" join

  return $?
}

rejoin_domain() {
  rejoin_log "Rejoin requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    rejoin_log "Required internal component not found"
    return 1
  fi

  detect_domain_state
  rejoin_log "Detected domain config state: ${DETECTED_DOMAIN_STATE}"
  cleanup_log "Detected state: ${DETECTED_DOMAIN_STATE}"

  if [[ "$DETECTED_DOMAIN_STATE" != "not_joined" ]]; then
    warn "Domain-related configuration was found:"
    printf '  - %s\n' "${DETECTED_DOMAIN_REASONS[@]}"
    rejoin_log "Detected config indicators: ${DETECTED_DOMAIN_REASONS[*]}"

    if ! confirm_safe_leave; then
      warn "Safe leave cancelled by user"
      rejoin_log "Safe leave cancelled by user"
      return 0
    fi

    if ! safe_leave_domain; then
      error "Safe domain leave failed"
      rejoin_log "Safe leave failed"
      return 1
    fi

    info "Return to main menu and run Configure domain join when ready"
    rejoin_log "Returning to main menu after safe leave"
    return 0
  fi

  info "No domain-related configuration detected. Starting normal join flow."
  rejoin_log "No domain-related configuration detected; running configure flow"
  run_configure_flow
  local code=$?
  rejoin_log "run_configure_flow exit code: ${code}"
  return "$code"
}

handle_missing_dependencies() {
  error "Dependency validation failed after installation."
  warn "Run 'Install required packages' from the main menu and check the installer log if this repeats."
  warn "Configuration will not install packages automatically."
  return 1
}

run_configure_flow() {
  if check_dependencies; then
    configure_domain
    return $?
  fi

  handle_missing_dependencies
}

reboot_system() {
  local choice reboot_cmd rc

  cleanup_log "[INFO] User selected PC reboot from main menu."

  printf '\nAre you sure you want to reboot this PC?\n\n'
  printf '1) Yes\n'
  printf '2) No\n'
  printf 'Select an option: '
  read_clean_input choice || choice=""

  case "$choice" in
    1)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: reboot PC"
        return 0
      fi

      info "Rebooting PC..."

      if reboot_cmd="$(find_executable systemctl)"; then
        "$reboot_cmd" reboot
        rc=$?
      else
        rc=1
      fi

      if [[ "$rc" -ne 0 ]] && reboot_cmd="$(find_executable reboot)"; then
        "$reboot_cmd"
        rc=$?
      fi

      if [[ "$rc" -eq 0 ]]; then
        sleep 1
        exit 0
      fi

      error "Failed to reboot the system."
      return 1
      ;;
    2)
      return 0
      ;;
    "")
      warn "Empty input. Returning to main menu."
      return 0
      ;;
    *)
      warn "Invalid option. Returning to main menu."
      return 0
      ;;
  esac
}

show_menu() {
  cat <<EOF

========================================
 Join to Domain
========================================
1) Install required packages
2) Configure domain join
3) Rejoin domain
4) Reboot PC
5) Exit
EOF
}

main_menu() {
  local choice

  while true; do
    show_menu
    printf 'Select an option: '
    read_clean_input choice || choice=""

    case "$choice" in
      1)
        install_packages
        pause
        ;;
      2)
        run_configure_flow
        pause
        ;;
      3)
        rejoin_domain
        pause
        ;;
      4)
        reboot_system
        ;;
      5|q|Q|exit|quit)
        info "Exiting"
        exit 0
        ;;
      "")
        warn "Empty input. Please select a menu item."
        ;;
      *)
        warn "Invalid option. Please select 1, 2, 3, 4 or 5."
        ;;
    esac
  done
}
