switch_from_existing_domain() {
  local current_domain current_short_hostname reason

  load_join_state
  current_domain="${SAVED_DOMAIN:-unknown}"
  current_short_hostname="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  valid_hostname "$current_short_hostname" \
    || die "$(ui_text "The current computer name is invalid: ${current_short_hostname}" "Текущее имя компьютера некорректно: ${current_short_hostname}")"

  user_info "$(ui_text "Replacing existing membership in ${current_domain} with the new domain" "Замена существующего членства в домене ${current_domain} на новый домен")"
  log "The old server-side computer and Salt objects are not modified during a Windows-style domain switch"
  if ! MD_DOMAIN_SWITCH_ACTIVE=1 MD_CALLED_FROM_INSTALL_PACKAGES=1 \
    bash "${SCRIPT_DIR}/configure.sh" local-leave-for-switch < /dev/tty; then
    error "$(ui_text "Could not restore the local pre-join configuration; the new Join was not started" "Не удалось восстановить локальную конфигурацию до старого Join; присоединение к новому домену не запущено")"
    return 1
  fi

  # Local cleanup restores /etc/hostname from before the original Join. Keep
  # the name the computer had immediately before this domain switch, matching
  # Windows behavior. It is applied later, inside the new Join transaction.
  MD_SWITCH_HOSTNAME="$current_short_hostname"

  detect_domain_state
  if [[ "$DETECTED_DOMAIN_STATE" == "managed_join" ]] || recoverable_incomplete_join_detected; then
    for reason in "${DETECTED_DOMAIN_REASONS[@]}"; do
      log "State remaining after old-domain cleanup: ${reason}"
    done
    error "$(ui_text "Old domain configuration is still present; the new Join was stopped" "Конфигурация старого домена всё ещё обнаружена; присоединение к новому домену остановлено")"
    return 1
  fi

  user_ok "$(ui_text "Old domain membership removed; starting Join to the new domain" "Членство в старом домене удалено; начинается присоединение к новому домену")"
  return 0
}

join_domain() {
  preflight
  user_info "$(ui_text "Starting domain join" "Начинается присоединение к домену")"

  if recoverable_incomplete_join_detected; then
    recover_incomplete_join_state
  fi

  detect_domain_state
  if [[ "$DETECTED_DOMAIN_STATE" != "not_joined" ]]; then
    if [[ "$DETECTED_DOMAIN_STATE" == "managed_join" ]]; then
      switch_from_existing_domain || return $?
    else
      warn "$(ui_text "Partial domain configuration already exists" "Обнаружена частичная доменная конфигурация")"
      die "$(ui_text "Use 'Rejoin domain' from the main menu to repair it." "Используйте пункт «Повторно присоединить к домену» для её восстановления.")"
    fi
  fi

  load_join_state

  # Everything above is read-only. Start transactional state and rollback only
  # immediately before the first possible system modification (TLS trust).
  activity_start "$(ui_text "Creating a safe pre-join backup" "Создание безопасной резервной копии перед присоединением")"
  create_join_backup || die "Failed to create a safe pre-join backup"
  validate_join_backup || die "Failed to validate the safe pre-join backup"
  write_transaction_state JOIN_IN_PROGRESS join || die "Failed to write join transaction state"
  activity_stop
  ok "$(ui_text "Backup created" "Резервная копия создана")"
  md_init_state
  MD_JOIN_ROLLBACK_ACTIVE=1
  MD_JOIN_FAILURE_REPORTED=0
  MD_JOIN_PHASE="domain_join"
  trap on_join_error ERR
  trap on_join_signal INT TERM

  prepare_service_info || die "$(ui_text "Failed to obtain domain settings from MultiDirectory" "Не удалось получить параметры домена от MultiDirectory")"
  validate_files_structure
  require_salt_minion_ready
  prompt_configure_dns

  while true; do
    read_tty LOGIN "$(ui_text "Enter administrator login, for example admin:" "Введите логин администратора, например admin:")"
    read_secret_tty PASSWORD "$(ui_text "Enter administrator password:" "Введите пароль администратора:")"
    if [[ -z "${LOGIN}" || -z "${PASSWORD}" ]]; then
      warn "$(ui_text "Login and password must be filled." "Логин и пароль не могут быть пустыми.")"
      continue
    fi
    activity_start "$(ui_text "Checking administrator credentials" "Проверка учётных данных администратора")"
    log "Authenticating domain administrator via API"
    if access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")" && [[ -n "${access_token}" ]]; then
      activity_stop
      log "Domain administrator credentials are valid"
      ok "$(ui_text "Administrator authentication succeeded" "Аутентификация администратора выполнена")"
      break
    else
      activity_stop
      warn "$(ui_text "Authentication failed. Please check login and password." "Ошибка аутентификации. Проверьте логин и пароль.")"
    fi
  done
  MD_JOIN_PHASE="domain_discovery"
  activity_start "$(ui_text "Detecting domain settings" "Определение параметров домена")"
  discover_and_validate_domain
  MD_JOIN_PHASE="domain_join"
  user_info "$(ui_text "Domain detected: ${DOMAIN}" "Обнаружен домен: ${DOMAIN}")"

  prompt_change_hostname

  log "DOMAIN=${DOMAIN}"
  log "REALM=${REALM}"
  log "LDAP_BASE_DN=${LDAP_BASE_DN}"
  log "HOSTNAME=${HOSTNAME}"
  log "FQDN=${FQDN}"
  log "EDITION=${EDITION}"
  log "WITH_SALT=${WITH_SALT}"

  activity_start "$(ui_text "Configuring the system" "Настройка системы")"
  install_static_configs
  validate_no_password_based_sssd_auth
  validate_sssd_config
  activity_stop
  ok "$(ui_text "System configuration completed" "Настройка системы завершена")"

  activity_start "$(ui_text "Creating domain membership" "Создание членства в домене")"
  info "$(ui_text "Configuring computer account" "Настройка учётной записи компьютера")"
  create_computer_object_if_needed
  ok "$(ui_text "Computer account ready" "Учётная запись компьютера готова")"

  info "$(ui_text "Configuring Kerberos" "Настройка Kerberos")"
  log "Getting keytab"
  api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${FQDN}"

  validate_keytab
  configure_sssd_keytab_principal
  validate_sssd_config
  ok "$(ui_text "Kerberos authentication succeeded" "Аутентификация Kerberos выполнена")"
  info "$(ui_text "Checking LDAP GSSAPI authentication" "Проверка аутентификации LDAP GSSAPI")"
  validate_ldap_gssapi_auth
  ok "$(ui_text "LDAP GSSAPI authentication succeeded" "Аутентификация LDAP GSSAPI выполнена")"
  configure_astra_se_parsec_sssd
  activity_stop

  if [[ "${WITH_SALT}" == "1" ]]; then
    activity_start "$(ui_text "Configuring Salt minion" "Настройка Salt minion")"
  fi
  configure_salt
  if [[ "${WITH_SALT}" == "1" ]]; then
    activity_stop
    ok "$(ui_text "Salt minion configured" "Salt minion настроен")"
  fi

  unset PASSWORD

  activity_start "$(ui_text "Starting services and saving state" "Запуск служб и сохранение состояния")"
  start_services
  publish_original_backup "$MD_BACKUP_DIR" || die "Failed to publish the immutable original backup"
  save_join_env
  rm -f "${MD_ROLLBACK_MARKER}" "${MD_PENDING_BACKUP}" "${MD_TRANSACTION_STATE}"

  MD_JOIN_ROLLBACK_ACTIVE=0
  trap - ERR INT TERM
  activity_stop

  user_ok "$(ui_text "Successfully joined domain: ${DOMAIN}" "Компьютер успешно присоединён к домену: ${DOMAIN}")"
  user_info "$(ui_text "System reboot is recommended" "Рекомендуется перезагрузить компьютер")"
}

require_install_packages_launcher() {
  if [[ "${MD_CALLED_FROM_INSTALL_PACKAGES:-0}" != "1" ]]; then
    if [[ -w /dev/tty ]]; then
      echo "[ERR] Use the public launcher: sudo ${PUBLIC_LAUNCHER}" > /dev/tty
    else
      echo "[ERR] Use the public launcher: sudo ${PUBLIC_LAUNCHER}" >&2
    fi
    exit 126
  fi
}

main() {
  require_install_packages_launcher "${1:-join}"

  case "${1:-}" in
    join)
      join_domain
      ;;
    leave)
      leave_domain
      ;;
    rejoin)
      rejoin_domain_configure
      ;;
    renew-certificate)
      renew_md_server_certificate
      ;;
    local-leave-for-switch)
      leave_domain_locally_for_switch
      ;;
    *)
      usage
      ;;
  esac
}
