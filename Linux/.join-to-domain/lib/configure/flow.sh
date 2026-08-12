prompt_api_address() {
  local entered default_address dns_failure_choice supplied_address=""

  if env_has_key API_ADDRESS; then
    supplied_address="${API_ADDRESS:-}"
    [[ -n "$supplied_address" ]] || die "API_ADDRESS is empty in environment"
  elif env_has_key API_HOST; then
    supplied_address="${API_HOST:-}"
    [[ -n "$supplied_address" ]] || die "API_HOST is empty in environment"
  fi

  if [[ -n "$supplied_address" ]]; then
    set_api_address "$supplied_address" \
      || die "Invalid API address in environment: ${supplied_address}"
    api_host_resolution_ok "$API_ADDRESS" \
      || die "$(ui_text "DNS resolution failed for API address from environment: ${API_ADDRESS}" "Не удалось разрешить адрес API из окружения через DNS: ${API_ADDRESS}")"
    return 0
  fi

  default_address="${API_ADDRESS:-${SAVED_API_ADDRESS:-${SAVED_API_HOST:-}}}"
  while true; do
    entered=""
    if [[ -n "$default_address" ]]; then
      read_tty entered "$(tr_text prompt.md_server)"
      entered="${entered:-$default_address}"
    else
      read_tty entered "$(tr_text prompt.md_server)"
    fi

    if ! set_api_address "$entered"; then
      warn "$(ui_text "Invalid API address. Enter an IPv4 address, domain, or FQDN." "Некорректный адрес API. Введите IPv4-адрес, домен или FQDN.")"
      continue
    fi

    if api_host_resolution_ok "$API_ADDRESS"; then
      if valid_ipv4_address "$API_ADDRESS"; then
        info "$(ui_text "Using controller IP address: ${API_ADDRESS}" "Используется IP-адрес контроллера: ${API_ADDRESS}")"
      else
        log "DNS resolution OK: ${API_ADDRESS}"
      fi
      return 0
    fi

    warn "$(ui_text "DNS resolution failed for ${API_ADDRESS}. Please check the address." "Не удалось разрешить ${API_ADDRESS} через DNS. Проверьте адрес.")"
    show_dns_failure_summary
    while true; do
      tty_echo "${YELLOW}$(ui_text "What do you want to do?" "Что вы хотите сделать?")${NC}"
      tty_echo "1. $(ui_text "Enter another server address" "Ввести другой адрес сервера")"
      tty_echo "2. $(ui_text "Configure DNS servers" "Настроить DNS-серверы")"
      tty_echo "3. $(ui_text "Cancel domain operation" "Отменить операцию с доменом")"
      read_tty dns_failure_choice "$(ui_text "Select (1/2/3) [1]:" "Выберите (1/2/3) [1]:")"
      dns_failure_choice="${dns_failure_choice:-1}"
      case "$dns_failure_choice" in
        1) break ;;
        2)
          prompt_configure_dns
          if api_host_resolution_ok "$API_ADDRESS"; then
            return 0
          fi
          warn "$(ui_text "DNS resolution still fails for ${API_ADDRESS}." "${API_ADDRESS} по-прежнему не разрешается через DNS.")"
          show_dns_failure_summary
          ;;
        3) return 1 ;;
        *) warn "$(ui_text "Enter 1, 2 or 3." "Введите 1, 2 или 3.")" ;;
      esac
    done
  done
}

refresh_domain_membership() {
  local mode="${1:-normal}"
  local update_parsec="${2:-1}"

  info "$(ui_text "Configuring computer account" "Настройка учётной записи компьютера")"
  create_computer_object_if_needed
  ok "$(ui_text "Computer account ready" "Учётная запись компьютера готова")"

  if [[ "$mode" == "rejoin" ]]; then
    info "$(ui_text "Refreshing Kerberos keytab" "Обновление Kerberos keytab")"
  else
    info "$(ui_text "Configuring Kerberos" "Настройка Kerberos")"
  fi
  log "Getting a fresh keytab (${mode})"
  api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${FQDN}"
  if [[ "$mode" == "rejoin" ]]; then
    ok "$(ui_text "New Kerberos keytab installed" "Новый Kerberos keytab установлен")"
  fi

  validate_keytab
  ok "$(ui_text "Kerberos authentication succeeded" "Аутентификация Kerberos выполнена")"
  info "$(ui_text "Checking LDAP GSSAPI authentication" "Проверка аутентификации LDAP GSSAPI")"
  validate_ldap_gssapi_auth
  ok "$(ui_text "LDAP GSSAPI authentication succeeded" "Аутентификация LDAP GSSAPI выполнена")"

  if [[ "$update_parsec" -eq 1 ]]; then
    configure_astra_se_parsec_sssd
  fi

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    if [[ "$mode" == "rejoin" ]]; then
      info "$(ui_text "Refreshing Salt minion" "Обновление Salt minion")"
    else
      info "$(ui_text "Configuring Salt minion" "Настройка Salt minion")"
    fi
  fi
  configure_salt
  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    if [[ "$mode" == "rejoin" ]]; then
      ok "$(ui_text "Salt minion refreshed" "Salt minion обновлён")"
    else
      ok "$(ui_text "Salt minion configured" "Salt minion настроен")"
    fi
  fi

  start_services
}

join_domain() {
  local JOIN_MODE="${JOIN_MODE:-normal}"

  preflight
  info "$(ui_text "Starting domain join" "Начинается присоединение к домену")"

  if recoverable_incomplete_join_detected; then
    recover_incomplete_join_state
  fi

  detect_domain_state
  if [[ "$DETECTED_DOMAIN_STATE" != "not_joined" ]]; then
    warn "$(ui_text "Domain-related configuration already exists:" "Доменная конфигурация уже существует:")"
    printf '  - %s\n' "${DETECTED_DOMAIN_REASONS[@]}" > /dev/tty
    die "$(ui_text "Use 'Rejoin domain' from the main menu." "Используйте пункт «Повторно присоединить к домену» в главном меню.")"
  fi

  load_join_state

  load_or_prompt_edition
  validate_files_structure

  # Everything above is read-only. Start transactional state and rollback only
  # immediately before the first possible system modification (DNS setup).
  info "$(ui_text "Creating pre-join system backup" "Создание резервной копии системы перед присоединением")"
  create_join_backup || die "Failed to create a safe pre-join backup"
  ok "$(ui_text "Backup created" "Резервная копия создана")"
  md_init_state
  MD_JOIN_ROLLBACK_ACTIVE=1
  trap 'on_join_error "$?" "${BASH_SOURCE[0]}" "${FUNCNAME[0]:-main}" "$LINENO" "$BASH_COMMAND"' ERR
  trap on_join_signal INT TERM

  prompt_configure_dns
  prompt_api_address || {
    warn "$(ui_text "Domain join cancelled" "Присоединение к домену отменено")"
    return 1
  }

  install_md_server_certificate
  ok "$(ui_text "Connected to MultiDirectory server" "Соединение с сервером MultiDirectory установлено")"

  while true; do
    read_tty LOGIN "$(ui_text "Enter administrator login, for example admin:" "Введите логин администратора, например admin:")"
    read_secret_tty PASSWORD "$(ui_text "Enter administrator password:" "Введите пароль администратора:")"
    if [[ -z "${LOGIN}" || -z "${PASSWORD}" ]]; then
      warn "$(ui_text "Login and password must be filled." "Логин и пароль не могут быть пустыми.")"
      continue
    fi
    log "Authenticating domain administrator via API"
    if access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")" && [[ -n "${access_token}" ]]; then
      log "Domain administrator credentials are valid"
      ok "$(ui_text "Administrator authentication succeeded" "Аутентификация администратора выполнена")"
      break
    else
      warn "$(ui_text "Authentication failed. Please check login and password." "Ошибка аутентификации. Проверьте логин и пароль.")"
    fi
  done
  discover_and_validate_domain

  if [[ "$JOIN_MODE" == "rejoin" ]]; then
    select_rejoin_hostname
  else
    prompt_change_hostname
  fi

  log "DOMAIN=${DOMAIN}"
  log "REALM=${REALM}"
  log "LDAP_BASE_DN=${LDAP_BASE_DN}"
  log "HOSTNAME=${HOSTNAME}"
  log "FQDN=${FQDN}"
  log "EDITION=${EDITION}"
  log "WITH_SALT=${WITH_SALT}"

  info "$(ui_text "Configuring system" "Настройка системы")"
  install_static_configs
  validate_no_password_based_sssd_auth
  validate_sssd_config
  ok "$(ui_text "System configuration completed" "Настройка системы завершена")"

  refresh_domain_membership normal 1

  unset PASSWORD

  save_join_env
  rm -f "${MD_ROLLBACK_MARKER}" "${MD_PENDING_BACKUP}"

  MD_JOIN_ROLLBACK_ACTIVE=0
  trap - ERR INT TERM

  ok "$(ui_text "Successfully joined domain: ${DOMAIN}" "Компьютер успешно присоединён к домену: ${DOMAIN}")"
  info "$(ui_text "System reboot is recommended" "Рекомендуется перезагрузить компьютер")"
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
      JOIN_MODE=normal join_domain
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
    *)
      usage
      ;;
  esac
}
