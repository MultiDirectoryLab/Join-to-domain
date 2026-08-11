existing_domain_configuration_valid() {
  [[ -s /etc/krb5.conf && -s /etc/sssd/sssd.conf ]] || return 1
  grep -Fqi "$REALM" /etc/krb5.conf || return 1
  grep -Fqi "$DOMAIN" /etc/sssd/sssd.conf || return 1
  if grep -Eq 'ldap_default_bind_dn|ldap_default_authtok|ldap_default_authtok_type|__SSSD_|__BIND_DN__|__PASSWORD__' /etc/sssd/sssd.conf; then
    return 1
  fi
  if have_cmd sssctl; then
    sssctl config-check >> "$LOG_FILE" 2>&1 || return 1
  fi
  [[ -n "$HOSTNAME" && -n "$FQDN" && -n "$LDAP_BASE_DN" ]]
}

classify_prejoin_backup() {
  local reference
  PREJOIN_BACKUP_STATE="legacy"
  PREJOIN_BACKUP_DIR=""
  PREJOIN_MANIFEST=""
  reference="$(join_state_value BACKUP_DIR 2>/dev/null || true)"

  if [[ -z "$reference" ]]; then
    warn "$(ui_text "Existing join state has no pre-join backup reference" "В состоянии предыдущего Join отсутствует ссылка на исходную резервную копию")"
    return 0
  fi
  PREJOIN_BACKUP_DIR="$reference"
  case "$reference" in "$MD_BACKUPS_ROOT"/join-*) ;; *) PREJOIN_BACKUP_STATE="corrupted"; return 0 ;; esac
  if ! load_prejoin_backup || ! validate_join_backup; then
    PREJOIN_BACKUP_STATE="corrupted"
    return 0
  fi
  PREJOIN_BACKUP_STATE="valid"
  PREJOIN_BACKUP_DIR="$MD_BACKUP_DIR"
  PREJOIN_MANIFEST="$MD_MANIFEST"
  info "$(ui_text "Previous join state and pre-join backup loaded" "Состояние предыдущего присоединения и исходная резервная копия загружены")"
}

rollback_recovery_changes() {
  local code="$1"
  warn "$(ui_text "Rejoin failed with exit code ${code}; restoring the configuration saved immediately before Rejoin" "Rejoin завершился с кодом ${code}; восстанавливается конфигурация, сохранённая непосредственно перед Rejoin")"
  MD_RESTORE_OPERATION_ONLY=1
  perform_local_rollback_cleanup
  MD_RESTORE_OPERATION_ONLY=0
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  MD_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  MD_MANIFEST="$PREJOIN_MANIFEST"
  rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"
  unset MD_ROLLBACK_HANDLER
  ok "$(ui_text "The pre-Rejoin configuration was restored; the original pre-join backup was preserved" "Конфигурация до Rejoin восстановлена; исходная резервная копия до Join сохранена")"
}

start_rejoin_transaction() {
  info "$(ui_text "Creating backup of current local configuration" "Создание резервной копии текущей локальной конфигурации")"
  create_recovery_backup || die "$(ui_text "Failed to create the Rejoin safety backup" "Не удалось создать страховочную резервную копию Rejoin")"
  ok "$(ui_text "Rejoin safety backup created" "Страховочная резервная копия Rejoin создана")"

  MD_ROLLBACK_HANDLER=rollback_recovery_changes
  MD_JOIN_ROLLBACK_ACTIVE=1
  trap on_recovery_rejoin_error ERR
  trap on_recovery_rejoin_signal INT TERM
}

on_recovery_rejoin_error() {
  local code=$?
  trap - ERR INT TERM
  MD_JOIN_ROLLBACK_ACTIVE=0
  rollback_recovery_changes "$code"
  exit "$code"
}

on_recovery_rejoin_signal() {
  trap - ERR INT TERM
  MD_JOIN_ROLLBACK_ACTIVE=0
  rollback_recovery_changes 130
  exit 130
}

recovery_rejoin_domain() {
  local system_config_updated=0

  if existing_domain_configuration_valid; then
    info "$(ui_text "Existing SSSD and Kerberos configuration is current and will be reused" "Существующая конфигурация SSSD и Kerberos актуальна и будет использована повторно")"
    validate_no_password_based_sssd_auth
    validate_sssd_config
  else
    info "$(ui_text "Domain configuration is incomplete; updating the required system files" "Доменная конфигурация неполна; обновляются необходимые системные файлы")"
    install_static_configs
    validate_no_password_based_sssd_auth
    validate_sssd_config
    system_config_updated=1
    ok "$(ui_text "Domain system configuration updated" "Системная конфигурация домена обновлена")"
  fi

  if [[ "${EXISTING_COMPUTER_FOUND:-0}" == "1" ]]; then
    if [[ "${EXISTING_COMPUTER_UAC:-}" =~ ^[0-9]+$ ]] && (( (EXISTING_COMPUTER_UAC & 2) != 0 )); then
      info "$(ui_text "Computer account is disabled; enabling it" "Учётная запись компьютера отключена; выполняется включение")"
    else
      info "$(ui_text "Computer account was found and is active" "Учётная запись компьютера найдена и активна")"
    fi
  else
    info "$(ui_text "Computer account was not found" "Учётная запись компьютера не найдена")"
    info "$(ui_text "Creating computer account" "Создание учётной записи компьютера")"
  fi
  refresh_domain_membership rejoin "$system_config_updated"
  printf 'COMPLETED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  JOIN_STATE_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  save_join_env
  unset JOIN_STATE_BACKUP_DIR
  rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"

  MD_JOIN_ROLLBACK_ACTIVE=0
  unset MD_ROLLBACK_HANDLER
  trap - ERR INT TERM
  ok "$(ui_text "Computer successfully rejoined the domain" "Компьютер успешно повторно присоединён к домену")"
  info "$(ui_text "The original pre-join backup was preserved for an explicit Leave" "Исходная резервная копия до Join сохранена для явного выхода из домена")"
}

infer_rejoin_edition() {
  if [[ "${SAVED_EDITION:-}" == "enterprise" && "${SAVED_WITH_SALT:-}" == "1" ]]; then
    EDITION=enterprise
    WITH_SALT=1
  elif [[ "${SAVED_EDITION:-}" == "community" && "${SAVED_WITH_SALT:-}" == "0" ]]; then
    EDITION=community
    WITH_SALT=0
  elif [[ -f /etc/salt/minion || -f /etc/salt/minion_id ]]; then
    EDITION=enterprise
    WITH_SALT=1
    log "Enterprise edition inferred from existing Salt configuration"
  else
    EDITION=community
    WITH_SALT=0
    log "Community edition inferred because no saved edition or Salt configuration exists"
  fi
}

prompt_rejoin_api_host() {
  local entered default_host

  if env_has_key API_HOST; then
    [[ -n "${API_HOST:-}" ]] || die "API_HOST is empty in environment"
    valid_join_domain "$API_HOST" \
      || die "$(ui_text "API_HOST must be a valid server FQDN" "API_HOST должен содержать корректный FQDN сервера")"
    return 0
  fi

  default_host="${API_HOST:-${SAVED_API_HOST:-}}"
  while true; do
    entered=""
    if [[ -n "$default_host" ]]; then
      read_tty entered "$(ui_text "Enter MULTIDIRECTORY server FQDN [${default_host}]:" "Введите FQDN сервера MULTIDIRECTORY [${default_host}]:")"
      entered="${entered:-$default_host}"
    else
      read_tty entered "$(ui_text "Enter MULTIDIRECTORY server FQDN:" "Введите FQDN сервера MULTIDIRECTORY:")"
    fi
    entered="$(printf '%s' "$entered" | tr '[:upper:]' '[:lower:]')"
    if valid_join_domain "$entered"; then
      API_HOST="$entered"
      return 0
    fi
    warn "$(ui_text "Enter a valid server FQDN" "Введите корректный FQDN сервера")"
  done
}

rejoin_domain_configure() {
  local supplied_api_host=""

  if env_has_key API_HOST; then
    supplied_api_host="${API_HOST:-}"
  fi

  need_root
  setup_logging
  load_os_release
  detect_domain_state

  if [[ "$DETECTED_DOMAIN_STATE" == "not_joined" ]]; then
    info "$(ui_text "No previous join was detected; starting the Join engine in Rejoin mode" "Предыдущее присоединение не обнаружено; запускается механизм Join в режиме Rejoin")"
    JOIN_MODE=rejoin join_domain
    return $?
  fi

  preflight

  LOCAL_JOIN_STATE="$DETECTED_DOMAIN_STATE"
  if [[ "$LOCAL_JOIN_STATE" == "managed_join" ]]; then
    info "$(ui_text "Previous local join configuration detected" "Обнаружена локальная конфигурация предыдущего присоединения")"
  else
    warn "$(ui_text "Partial MultiDirectory configuration detected" "Обнаружена частичная конфигурация MultiDirectory")"
  fi
  info "$(ui_text "Rejoin mode started" "Запущен режим Rejoin")"

  load_join_env
  if env_has_key API_HOST; then
    API_HOST="$supplied_api_host"
  fi
  infer_rejoin_edition
  validate_files_structure
  classify_prejoin_backup
  case "$PREJOIN_BACKUP_STATE" in
    valid) ;;
    legacy) warn "$(ui_text "No original pre-join backup reference is available; Rejoin can continue, but a future Leave cannot restore the original configuration" "Ссылка на исходную резервную копию до Join отсутствует; Rejoin продолжится, но будущий Leave не сможет восстановить исходную конфигурацию")" ;;
    corrupted) warn "$(ui_text "The original pre-join backup reference is invalid; it will not be replaced by the Rejoin safety backup" "Ссылка на исходную резервную копию до Join некорректна; страховочная копия Rejoin не заменит её")" ;;
  esac

  start_rejoin_transaction
  prompt_configure_dns
  if [[ -z "${MD_DNS_SERVER:-}" && -n "${SAVED_DNS_SERVERS:-}" ]]; then
    MD_DNS_SERVER="$SAVED_DNS_SERVERS"
    log "Preserving saved DNS servers in the refreshed join state"
  fi
  prompt_rejoin_api_host
  validate_directory_credentials state-loaded
  discover_and_validate_domain
  ok "$(ui_text "Administrator authentication succeeded" "Аутентификация администратора выполнена")"
  info "$(ui_text "Domain detected: ${DOMAIN}" "Обнаружен домен: ${DOMAIN}")"
  select_rejoin_hostname
  info "$(ui_text "Refreshing computer domain membership" "Обновление членства компьютера в домене")"
  recovery_rejoin_domain

  if [[ -n "${MD_EPHEMERAL_CA_BUNDLE:-}" ]]; then
    rm -f "$MD_EPHEMERAL_CA_BUNDLE"
    unset MD_EPHEMERAL_CA_BUNDLE CURL_CA_BUNDLE
  fi
}
