configure_domain() {
  log "INFO" "Domain configuration requested"

  if ! need_script "$CONFIGURE_SCRIPT"; then
    return 1
  fi

  detect_domain_state
  log_recovery_state
  if recoverable_incomplete_join_detected; then
    status_info "$(ui_text "An incomplete previous join was found. Local recovery will run before retrying." "Обнаружено незавершённое предыдущее присоединение. Перед новой попыткой будет выполнено локальное восстановление.")"
  elif [[ "$DETECTED_DOMAIN_STATE" != "not_joined" ]]; then
    if [[ "$DETECTED_DOMAIN_STATE" == "managed_join" ]]; then
      status_info "$(ui_text "Existing domain membership found; it will be replaced with the new domain membership" "Обнаружено членство в существующем домене; оно будет заменено членством в новом домене")"
    elif partial_without_recovery_metadata; then
      warn "$(ui_text "An incomplete Join has no original backup; cleaning only identifiable MultiDirectory components" "У незавершённого Join нет исходной резервной копии; очищаются только однозначно определяемые компоненты MultiDirectory")"
      safe_leave_domain || return 1
      detect_domain_state
      [[ "$DETECTED_DOMAIN_STATE" == "not_joined" ]] || {
        error "$(ui_text "Conservative recovery left ambiguous domain configuration; Join was stopped" "После консервативного восстановления осталась неоднозначная доменная конфигурация; Join остановлен")"
        return 1
      }
      status_info "$(ui_text "Incomplete state recovered; starting a clean Join" "Незавершённое состояние восстановлено; запускается чистый Join")"
    else
      warn "$(ui_text "Partial domain configuration cannot be identified safely" "Частичную доменную конфигурацию нельзя безопасно идентифицировать")"
      return 1
    fi
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

  detect_domain_state
  log_recovery_state
  if partial_without_recovery_metadata; then
    warn "$(ui_text "The original backup is unavailable; performing conservative MultiDirectory cleanup" "Исходная резервная копия недоступна; выполняется консервативная очистка компонентов MultiDirectory")"
    safe_leave_domain
    return $?
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

  detect_domain_state
  log_recovery_state
  if partial_without_recovery_metadata; then
    warn "$(ui_text "The original backup is unavailable; recovering identifiable MultiDirectory components before Rejoin" "Исходная резервная копия недоступна; перед Rejoin восстанавливаются однозначно определяемые компоненты MultiDirectory")"
    safe_leave_domain || return 1
    detect_domain_state
    [[ "$DETECTED_DOMAIN_STATE" == "not_joined" ]] || {
      error "$(ui_text "Conservative recovery could not produce a clean state" "Консервативное восстановление не смогло получить чистое состояние")"
      return 1
    }
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
