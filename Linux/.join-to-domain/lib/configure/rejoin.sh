resolve_computer_object() {
  local response filter base successful_search=0 search_count

  REMOTE_COMPUTER_DN=""
  REMOTE_COMPUTER_UAC=""
  REMOTE_COMPUTER_STATE="unknown"

  if [[ -n "${COMPUTER_DN:-}" ]]; then
    if response="$(api_search "$access_token" "$COMPUTER_DN" 0 '(objectClass=computer)' '["cn","userAccountControl"]' 1 2>/dev/null)"; then
      successful_search=1
      REMOTE_COMPUTER_DN="$(printf '%s' "$response" | jq -r '.search_result[0].object_name // empty')"
      REMOTE_COMPUTER_UAC="$(printf '%s' "$response" | jq -r '.search_result[0].partial_attributes[]? | select((.type | ascii_downcase)=="useraccountcontrol") | .vals[0] // empty' 2>/dev/null || true)"
    fi
  fi

  base="${LDAP_BASE_DN:-${LDAP_COMPUTER_OU:-}}"
  if [[ -z "$REMOTE_COMPUTER_DN" && -n "$base" ]]; then
    filter="(&(objectClass=computer)(|(cn=${HOSTNAME})(sAMAccountName=${HOSTNAME})(sAMAccountName=${HOSTNAME}\$)(servicePrincipalName=host/${FQDN})))"
    if response="$(api_search "$access_token" "$base" 2 "$filter" '["cn","objectGUID","userAccountControl"]' 10 2>/dev/null)"; then
      successful_search=1
      search_count="$(printf '%s' "$response" | jq -r '[.search_result[]? | select(.object_name != null)] | length' 2>/dev/null)" \
        || die "Invalid computer search response from LDAP"
      [[ "$search_count" =~ ^[0-9]+$ ]] || die "Invalid computer search response from LDAP"
      if (( search_count > 1 )); then
        printf '%s' "$response" | jq -r '.search_result[]?.object_name // empty' 2>/dev/null \
          | while IFS= read -r candidate_dn; do log "Duplicate computer candidate: ${candidate_dn}"; done
        die "Several matching computer objects were found in LDAP; resolve duplicates before continuing"
      fi
      REMOTE_COMPUTER_DN="$(printf '%s' "$response" | jq -r '.search_result[0].object_name // empty')"
      REMOTE_COMPUTER_UAC="$(printf '%s' "$response" | jq -r '.search_result[0].partial_attributes[]? | select((.type | ascii_downcase)=="useraccountcontrol") | .vals[0] // empty' 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$REMOTE_COMPUTER_DN" ]]; then
    REMOTE_COMPUTER_STATE="exists"
    COMPUTER_DN="$REMOTE_COMPUTER_DN"
  elif [[ "$successful_search" -eq 1 ]]; then
    REMOTE_COMPUTER_STATE="missing"
  fi
}

existing_domain_configuration_valid() {
  [[ -s /etc/krb5.conf && -s /etc/sssd/sssd.conf ]] || return 1
  grep -Fqi "$REALM" /etc/krb5.conf || return 1
  grep -Fqi "$DOMAIN" /etc/sssd/sssd.conf || return 1
  [[ -n "$HOSTNAME" && -n "$FQDN" && -n "$LDAP_BASE_DN" ]]
}

classify_prejoin_backup() {
  local reference
  PREJOIN_BACKUP_STATE="legacy"
  PREJOIN_BACKUP_DIR=""
  PREJOIN_MANIFEST=""
  reference="$(join_state_value BACKUP_DIR 2>/dev/null || true)"

  if [[ -z "$reference" ]]; then
    info "$(ui_text "Migrating legacy pre-join backup" "Перенос резервной копии старого формата")"
    if load_prejoin_backup && validate_join_backup; then
      PREJOIN_BACKUP_STATE="valid"
      PREJOIN_BACKUP_DIR="$MD_BACKUP_DIR"
      PREJOIN_MANIFEST="$MD_MANIFEST"
      ok "$(ui_text "Legacy backup migrated successfully" "Резервная копия старого формата успешно перенесена")"
      return 0
    fi
    warn "$(ui_text "The legacy pre-join backup is missing or corrupted; the computer remains joined, but Rejoin cannot continue safely" "Резервная копия старого формата отсутствует или повреждена; компьютер остаётся в домене, но безопасный Rejoin невозможен")"
    return 0
  fi
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

require_valid_prejoin_backup() {
  case "${PREJOIN_BACKUP_STATE:-legacy}" in
    valid) return 0 ;;
    legacy) die "Existing join state has no pre-join backup; local recovery rejoin is disabled to preserve a safe future leave" ;;
    corrupted) die "Existing join state contains an invalid pre-join backup reference. join.env: ${MD_JOIN_ENV}" ;;
  esac
}

rollback_recovery_changes() {
  local code="$1"
  activity_stop
  warn "Recovery rejoin failed with exit code ${code}; restoring the pre-rejoin configuration"
  activity_start "$(ui_text "Restoring the pre-rejoin configuration" "Восстановление конфигурации до повторного присоединения")"
  MD_RESTORE_OPERATION_ONLY=1
  perform_local_rollback_cleanup
  MD_RESTORE_OPERATION_ONLY=0
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  MD_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  MD_MANIFEST="$PREJOIN_MANIFEST"
  rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"
  MD_OPERATION_NM_DNS_STATE=""
  unset MD_ROLLBACK_HANDLER
  activity_stop
  user_ok "Pre-rejoin configuration restored; the original pre-join backup was preserved"
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
  activity_start "$(ui_text "Refreshing computer domain membership" "Обновление членства компьютера в домене")"
  case "${REMOTE_COMPUTER_STATE:-unknown}" in
    exists)
      info "$(ui_text "Existing computer account will be reused" "Существующая учётная запись компьютера будет использована повторно")"
      enable_computer_account_if_disabled "$COMPUTER_DN" "${REMOTE_COMPUTER_UAC:-}"
      ;;
    missing)
      info "$(ui_text "Computer account is missing and will be created" "Учётная запись компьютера отсутствует и будет создана")"
      create_computer_object_if_needed
      ;;
    *)
      die "Failed to determine the computer object state in LDAP"
      ;;
  esac

  info "$(ui_text "Requesting new Kerberos keytab" "Запрос нового Kerberos keytab")"
  api_ktadd_download "$access_token" "host/${HOSTNAME}" "host/${FQDN}"
  validate_keytab
  ok "$(ui_text "Kerberos authentication succeeded" "Аутентификация Kerberos выполнена")"
  validate_ldap_gssapi_auth
  ok "$(ui_text "LDAP GSSAPI authentication succeeded" "Аутентификация LDAP GSSAPI выполнена")"

  configure_salt
  start_services
  printf 'COMPLETED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  JOIN_STATE_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  save_join_env
  unset JOIN_STATE_BACKUP_DIR
  rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"

  MD_JOIN_ROLLBACK_ACTIVE=0
  unset MD_ROLLBACK_HANDLER
  trap - ERR INT TERM
  if [[ -n "${MD_OPERATION_NM_DNS_STATE:-}" ]]; then
    rm -f "$MD_OPERATION_NM_DNS_STATE" || warn "Failed to remove the completed Rejoin DNS snapshot"
  fi
  MD_OPERATION_NM_DNS_STATE=""
  MD_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  MD_MANIFEST="$PREJOIN_MANIFEST"
  activity_stop
  user_ok "$(ui_text "Computer successfully rejoined the domain" "Компьютер успешно повторно присоединён к домену")"
  user_info "$(ui_text "System reboot is recommended" "Рекомендуется перезагрузить компьютер")"
}

start_rejoin_transaction() {
  activity_start "$(ui_text "Creating a recovery backup" "Создание резервной копии для восстановления")"
  create_recovery_backup || die "Failed to create the recovery rejoin operation backup"
  activity_stop
  ok "$(ui_text "Recovery backup created" "Резервная копия для восстановления создана")"

  MD_ROLLBACK_HANDLER=rollback_recovery_changes
  MD_JOIN_ROLLBACK_ACTIVE=1
  trap on_recovery_rejoin_error ERR
  trap on_recovery_rejoin_signal INT TERM
}

rejoin_domain_configure() {
  local supplied_api_host=""
  local supplied_api_host_set=0

  if env_has_key API_HOST; then
    supplied_api_host="${API_HOST:-}"
    supplied_api_host_set=1
  fi

  need_root
  setup_logging
  load_os_release
  user_info "$(ui_text "Starting domain rejoin" "Начинается повторное присоединение к домену")"

  if recoverable_incomplete_join_detected; then
    recover_incomplete_join_state
  fi

  detect_domain_state

  if [[ "$DETECTED_DOMAIN_STATE" == "not_joined" ]]; then
    info "$(ui_text "Domain configuration not found; starting normal domain join" "Конфигурация домена не обнаружена; запускается обычное присоединение")"
    join_domain
    return $?
  fi

  LOCAL_JOIN_STATE="$DETECTED_DOMAIN_STATE"
  if [[ "$LOCAL_JOIN_STATE" == "managed_join" ]]; then
    info "$(ui_text "Existing local domain configuration found" "Обнаружена локальная конфигурация домена")"
  else
    warn "$(ui_text "Partial MultiDirectory configuration detected" "Обнаружена частичная конфигурация MultiDirectory")"
    info "$(ui_text "Remote computer state must be verified" "Необходимо проверить состояние компьютера в каталоге")"
  fi

  load_join_env
  if [[ "$supplied_api_host_set" -eq 1 ]]; then
    [[ -n "$supplied_api_host" ]] || die "API_HOST is empty in environment"
    valid_api_host "$supplied_api_host" || die "Invalid API_HOST in environment: ${supplied_api_host}"
    API_HOST="$supplied_api_host"
  fi
  if [[ -z "${MD_DNS_SERVER:-}" && -n "${SAVED_DNS_SERVERS:-}" ]]; then
    MD_DNS_SERVER="$SAVED_DNS_SERVERS"
  fi
  classify_prejoin_backup
  case "$PREJOIN_BACKUP_STATE" in
    valid) ;;
    legacy) warn "$(ui_text "The legacy backup could not be migrated; Rejoin is disabled to avoid damaging the current domain configuration" "Не удалось перенести резервную копию старого формата; Rejoin отключён, чтобы не повредить текущую доменную конфигурацию")" ;;
    corrupted) warn "$(ui_text "The pre-join backup reference is corrupted; Rejoin is disabled" "Ссылка на исходную резервную копию повреждена; Rejoin отключён")" ;;
  esac
  require_valid_prejoin_backup
  existing_domain_configuration_valid \
    || die "Existing domain configuration is incomplete or does not match the saved domain"
  info "$(ui_text "Existing domain configuration is valid and will be reused" "Существующая доменная конфигурация корректна и будет использована повторно")"

  start_rejoin_transaction
  validate_leave_credentials state-loaded
  discover_and_validate_domain
  if [[ -z "${HOSTNAME:-}" ]]; then
    HOSTNAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  fi
  [[ -n "${FQDN:-}" ]] || FQDN="${HOSTNAME}.${DOMAIN}"
  ok "$(ui_text "Directory administrator authentication succeeded" "Аутентификация администратора каталога выполнена")"
  resolve_computer_object
  recovery_rejoin_domain

  if [[ -n "${MD_EPHEMERAL_CA_BUNDLE:-}" ]]; then
    rm -f "$MD_EPHEMERAL_CA_BUNDLE"
    unset MD_EPHEMERAL_CA_BUNDLE CURL_CA_BUNDLE
  fi
}
