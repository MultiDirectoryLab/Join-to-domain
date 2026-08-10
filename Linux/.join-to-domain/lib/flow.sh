configure_domain() {
  log "INFO" "Domain configuration requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  detect_domain_state
  if recoverable_incomplete_join_detected; then
    status_info "$(ui_text "An incomplete previous join was found. Local recovery will run before retrying." "Обнаружено незавершённое предыдущее присоединение. Перед новой попыткой будет выполнено локальное восстановление.")"
  elif [[ "$DETECTED_DOMAIN_STATE" != "not_joined" ]]; then
    warn "$(ui_text "Domain-related configuration already exists. Use 'Rejoin domain'." "Доменная конфигурация уже существует. Используйте пункт «Повторно присоединить к домену».")"
    printf '  - %s\n' "${DETECTED_DOMAIN_REASONS[@]}"
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "$(ui_text "Domain configuration requires root. Run: sudo $0" "Для настройки домена требуются права root. Запустите: sudo $0")"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: run domain configuration"
    return 0
  fi

  info "$(ui_text "Running domain configuration" "Запуск настройки домена")"
  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" join

  return $?
}

leave_domain_from_menu() {
  log "INFO" "Domain leave requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "$(ui_text "Domain leave requires root. Run: sudo $0" "Для выхода из домена требуются права root. Запустите: sudo $0")"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: leave domain"
    return 0
  fi

  info "$(ui_text "Running domain leave" "Запуск выхода из домена")"
  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" leave < /dev/tty
}

renew_certificate_from_menu() {
  log "INFO" "TLS certificate renewal requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "$(ui_text "Certificate renewal requires root. Run: sudo $0" "Для обновления сертификата требуются права root. Запустите: sudo $0")"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: renew MultiDirectory TLS certificate"
    return 0
  fi

  info "$(ui_text "Renewing MultiDirectory TLS certificate" "Обновление TLS-сертификата MultiDirectory")"
  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" renew-certificate < /dev/tty
}

rejoin_domain() {
  rejoin_log "Rejoin requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    rejoin_log "Required internal component not found"
    return 1
  fi

  if ! check_dependencies; then
    handle_missing_dependencies
    return $?
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "$(ui_text "Domain rejoin requires root. Run: sudo $0" "Для повторного присоединения требуются права root. Запустите: sudo $0")"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: inspect local and remote rejoin state"
    return 0
  fi

  MD_CALLED_FROM_INSTALL_PACKAGES=1 bash "$CONFIGURE_SCRIPT" rejoin < /dev/tty
}

handle_missing_dependencies() {
  error "$(ui_text "Dependency validation failed after installation." "Проверка зависимостей после установки завершилась ошибкой.")"
  warn "$(ui_text "Run 'Install required packages' from the main menu and check the installer log if this repeats." "Запустите «Установить необходимые пакеты» из главного меню; если ошибка повторится, проверьте журнал установщика.")"
  warn "$(ui_text "Configuration will not install packages automatically." "Конфигуратор не будет устанавливать пакеты автоматически.")"
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
3) $(tr_text menu.leave)
4) $(tr_text menu.rejoin)
5) $(tr_text menu.renew_certificate)
6) $(tr_text menu.reboot)
7) $(tr_text menu.exit)
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
        leave_domain_from_menu
        pause
        ;;
      4)
        rejoin_domain
        pause
        ;;
      5)
        renew_certificate_from_menu
        pause
        ;;
      6)
        reboot_system
        ;;
      7|q|Q|exit|quit)
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
