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

leave_domain_from_menu() {
  log "INFO" "Domain leave requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Domain leave requires root. Run: sudo $0"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: leave domain"
    return 0
  fi

  info "Running domain leave"
  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" leave < /dev/tty
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

  printf '\n%s\n\n' "$(tr_text prompt.reboot)"
  printf '1) %s\n' "$(tr_text answer.yes)"
  printf '2) %s\n' "$(tr_text answer.no)"
  printf '%s: ' "$(tr_text prompt.select)"
  read_clean_input choice || choice=""

  case "$choice" in
    1)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: reboot PC"
        return 0
      fi

      info "$(tr_text status.rebooting)"

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

      error "$(tr_text error.reboot)"
      return 1
      ;;
    2)
      return 0
      ;;
    "")
      warn "$(tr_text status.return_menu)"
      return 0
      ;;
    *)
      warn "$(tr_text status.return_menu)"
      return 0
      ;;
  esac
}

show_menu() {
  cat <<EOF

========================================
 $(tr_text menu.title)
========================================
1) $(tr_text menu.install)
2) $(tr_text menu.join)
3) $(tr_text menu.rejoin)
4) $(tr_text menu.leave)
5) $(tr_text menu.reboot)
6) $(tr_text menu.exit)
EOF
}

main_menu() {
  local choice

  while true; do
    show_menu
    printf '%s: ' "$(tr_text prompt.select)"
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
        leave_domain_from_menu
        pause
        ;;
      5)
        reboot_system
        ;;
      6|q|Q|exit|quit)
        info "$(tr_text status.exiting)"
        exit 0
        ;;
      "")
        warn "$(tr_text error.empty_menu)"
        ;;
      *)
        warn "$(tr_text error.invalid_menu)"
        ;;
    esac
  done
}
