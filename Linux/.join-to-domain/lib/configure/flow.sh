join_domain() {
  local dns_failure_choice

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
  md_init_state
  MD_JOIN_ROLLBACK_ACTIVE=1
  trap on_join_error ERR
  trap on_join_signal INT TERM

  prompt_configure_dns

  if env_has_key API_HOST; then
    [[ -n "${API_HOST:-}" ]] || die "API_HOST is empty in environment"
    valid_api_host "${API_HOST}" || die "Invalid API_HOST in environment: ${API_HOST}"
    if api_host_resolution_ok "${API_HOST}"; then
      if valid_ipv4_address "${API_HOST}"; then
        log "API host is an IPv4 address; DNS resolution skipped: ${API_HOST}"
      else
        log "DNS resolution OK: ${API_HOST}"
      fi
    else
      die "$(ui_text "DNS resolution failed for API_HOST from environment: ${API_HOST}" "Не удалось разрешить API_HOST из окружения через DNS: ${API_HOST}")"
    fi
  else
    while true; do
      if [[ -n "${SAVED_API_HOST:-}" ]]; then
        read_tty API_HOST "$(ui_text "Enter MULTIDIRECTORY server FQDN [${SAVED_API_HOST}]:" "Введите FQDN сервера MULTIDIRECTORY [${SAVED_API_HOST}]:")"
        API_HOST="${API_HOST:-$SAVED_API_HOST}"
      else
        read_tty API_HOST "$(ui_text "Enter MULTIDIRECTORY server FQDN, for example webadmin.domain.ru:" "Введите FQDN сервера MULTIDIRECTORY, например webadmin.domain.ru:")"
      fi
      if [[ -z "${API_HOST}" ]]; then
        warn "$(ui_text "API host must be filled." "Адрес API не может быть пустым.")"
        continue
      fi
      if valid_ipv4_address "${API_HOST}" || ! valid_join_domain "${API_HOST}"; then
        warn "$(ui_text "Invalid API host. Enter a server FQDN, for example webadmin.domain.ru." "Некорректный адрес API. Введите FQDN сервера, например webadmin.domain.ru.")"
        continue
      fi
      if api_host_resolution_ok "${API_HOST}"; then
        if valid_ipv4_address "${API_HOST}"; then
          log "API host is an IPv4 address; DNS resolution skipped: ${API_HOST}"
        else
          log "DNS resolution OK: ${API_HOST}"
        fi
        break
      else
        warn "$(ui_text "DNS resolution failed for ${API_HOST}. Please check the address." "Не удалось разрешить ${API_HOST} через DNS. Проверьте адрес.")"

        while true; do
          tty_echo "${YELLOW}$(ui_text "What do you want to do?" "Что вы хотите сделать?")${NC}"
          tty_echo "1. $(ui_text "Enter another server address" "Ввести другой адрес сервера")"
          tty_echo "2. $(ui_text "Configure DNS servers" "Настроить DNS-серверы")"
          tty_echo "3. $(ui_text "Cancel domain join" "Отменить присоединение к домену")"
          read_tty dns_failure_choice "$(ui_text "Select (1/2/3) [1]:" "Выберите (1/2/3) [1]:")"
          dns_failure_choice="${dns_failure_choice:-1}"

          case "$dns_failure_choice" in
            1)
              break
              ;;
            2)
              prompt_configure_dns

              if api_host_resolution_ok "${API_HOST}"; then
                if valid_ipv4_address "${API_HOST}"; then
                  log "API host is an IPv4 address; DNS resolution skipped: ${API_HOST}"
                else
                  log "DNS resolution OK after DNS configuration: ${API_HOST}"
                fi
                break 2
              fi

              warn "$(ui_text "DNS resolution still fails for ${API_HOST}." "${API_HOST} по-прежнему не разрешается через DNS.")"
              ;;
            3)
              warn "$(ui_text "Domain join cancelled" "Присоединение к домену отменено")"
              return 1
              ;;
            *)
              warn "$(ui_text "Enter 1, 2 or 3." "Введите 1, 2 или 3.")"
              ;;
          esac
        done
      fi
    done
  fi

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
  info "$(ui_text "Domain detected: ${DOMAIN}" "Обнаружен домен: ${DOMAIN}")"

  prompt_change_hostname

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

  info "$(ui_text "Configuring computer account" "Настройка учётной записи компьютера")"
  create_computer_object_if_needed
  ok "$(ui_text "Computer account ready" "Учётная запись компьютера готова")"

  info "$(ui_text "Configuring Kerberos" "Настройка Kerberos")"
  log "Getting keytab"
  api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${FQDN}"

  validate_keytab
  ok "$(ui_text "Kerberos authentication succeeded" "Аутентификация Kerberos выполнена")"
  info "$(ui_text "Checking LDAP GSSAPI authentication" "Проверка аутентификации LDAP GSSAPI")"
  validate_ldap_gssapi_auth
  ok "$(ui_text "LDAP GSSAPI authentication succeeded" "Аутентификация LDAP GSSAPI выполнена")"
  configure_astra_se_parsec_sssd

  if [[ "${WITH_SALT}" == "1" ]]; then
    info "$(ui_text "Configuring Salt minion" "Настройка Salt minion")"
  fi
  configure_salt
  if [[ "${WITH_SALT}" == "1" ]]; then
    ok "$(ui_text "Salt minion configured" "Salt minion настроен")"
  fi

  unset PASSWORD

  save_join_env
  rm -f "${MD_ROLLBACK_MARKER}"
  start_services

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
      join_domain
      ;;
    leave)
      leave_domain
      ;;
    renew-certificate)
      renew_md_server_certificate
      ;;
    *)
      usage
      ;;
  esac
}
