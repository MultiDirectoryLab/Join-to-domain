resolve_computer_object() {
  local response filter base successful_search=0

  REMOTE_COMPUTER_DN=""
  REMOTE_COMPUTER_STATE="unknown"

  if [[ -n "${COMPUTER_DN:-}" ]]; then
    if response="$(api_search "$access_token" "$COMPUTER_DN" 0 '(objectClass=computer)' '["cn"]' 1 2>/dev/null)"; then
      successful_search=1
      REMOTE_COMPUTER_DN="$(printf '%s' "$response" | jq -r '.search_result[0].object_name // empty')"
    fi
  fi

  base="${LDAP_BASE_DN:-${LDAP_COMPUTER_OU:-}}"
  if [[ -z "$REMOTE_COMPUTER_DN" && -n "$base" ]]; then
    for filter in \
      "(&(objectClass=computer)(sAMAccountName=${HOSTNAME}\$))" \
      "(&(objectClass=computer)(sAMAccountName=${HOSTNAME}))" \
      "(&(objectClass=computer)(cn=${HOSTNAME}))" \
      "(&(objectClass=computer)(servicePrincipalName=host/${FQDN}))"; do
      if response="$(api_search "$access_token" "$base" 2 "$filter" '["cn","objectGUID","userAccountControl"]' 1 2>/dev/null)"; then
        successful_search=1
        REMOTE_COMPUTER_DN="$(printf '%s' "$response" | jq -r '.search_result[0].object_name // empty')"
      fi
      [[ -z "$REMOTE_COMPUTER_DN" ]] || break
    done
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
    warn "Existing join state was created without a pre-join backup reference"
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
  warn "Recovery rejoin failed with exit code ${code}; restoring the pre-rejoin configuration"
  MD_RESTORE_OPERATION_ONLY=1
  perform_local_rollback_cleanup
  MD_RESTORE_OPERATION_ONLY=0
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  MD_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  MD_MANIFEST="$PREJOIN_MANIFEST"
  rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"
  unset MD_ROLLBACK_HANDLER
  ok "Pre-rejoin configuration restored; the original pre-join backup was preserved"
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
  require_valid_prejoin_backup
  existing_domain_configuration_valid \
    || die "Existing domain configuration is incomplete or does not match the saved domain"

  info "$(ui_text "Existing domain configuration is valid and will be reused" "Существующая доменная конфигурация корректна и будет использована повторно")"
  info "$(ui_text "Creating backup of current local configuration" "Создание резервной копии текущей локальной конфигурации")"
  create_recovery_backup || die "Failed to create the recovery rejoin operation backup"
  ok "$(ui_text "Recovery backup created" "Резервная копия для восстановления создана")"

  MD_ROLLBACK_HANDLER=rollback_recovery_changes
  MD_JOIN_ROLLBACK_ACTIVE=1
  trap on_recovery_rejoin_error ERR
  trap on_recovery_rejoin_signal INT TERM

  info "$(ui_text "Recreating computer account" "Повторное создание учётной записи компьютера")"
  create_computer_object_if_needed
  ok "$(ui_text "Computer account created" "Учётная запись компьютера создана")"

  info "$(ui_text "Requesting new Kerberos keytab" "Запрос нового Kerberos keytab")"
  api_ktadd_download "$access_token" "host/${HOSTNAME}" "host/${FQDN}"
  validate_keytab
  ok "$(ui_text "Kerberos authentication succeeded" "Аутентификация Kerberos выполнена")"
  validate_ldap_gssapi_auth
  ok "$(ui_text "LDAP GSSAPI authentication succeeded" "Аутентификация LDAP GSSAPI выполнена")"

  configure_salt
  start_services
  printf 'COMPLETED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  MD_BACKUP_DIR="$PREJOIN_BACKUP_DIR"
  MD_MANIFEST="$PREJOIN_MANIFEST"
  save_join_env
  rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"

  MD_JOIN_ROLLBACK_ACTIVE=0
  unset MD_ROLLBACK_HANDLER
  trap - ERR INT TERM
  ok "$(ui_text "Computer successfully rejoined the domain" "Компьютер успешно повторно присоединён к домену")"
}

rejoin_domain_configure() {
  need_root
  setup_logging
  load_os_release
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

  classify_prejoin_backup
  case "$PREJOIN_BACKUP_STATE" in
    valid) ;;
    legacy) warn "$(ui_text "Existing join state has no pre-join backup; only non-destructive LDAP inspection is available" "В существующем состоянии нет исходной резервной копии; доступна только безопасная проверка LDAP")" ;;
    corrupted) warn "$(ui_text "The pre-join backup reference is corrupted; local changes are disabled" "Ссылка на исходную резервную копию повреждена; локальные изменения запрещены")" ;;
  esac

  validate_leave_credentials
  discover_and_validate_domain
  if [[ -z "${HOSTNAME:-}" ]]; then
    HOSTNAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  fi
  [[ -n "${FQDN:-}" ]] || FQDN="${HOSTNAME}.${DOMAIN}"
  ok "$(ui_text "Directory administrator authentication succeeded" "Аутентификация администратора каталога выполнена")"
  resolve_computer_object

  if [[ "$REMOTE_COMPUTER_STATE" == "exists" ]]; then
    info "$(ui_text "Computer object exists in LDAP" "Учётная запись компьютера найдена в LDAP")"
    info "$(ui_text "Leaving the domain" "Выполняется выход из домена")"
    require_valid_prejoin_backup
    perform_authenticated_leave
  elif [[ "$REMOTE_COMPUTER_STATE" == "missing" ]]; then
    warn "$(ui_text "Computer object is missing from LDAP" "Учётная запись компьютера отсутствует в LDAP")"
    info "$(ui_text "Starting computer membership recovery" "Запускается восстановление членства компьютера в домене")"
    recovery_rejoin_domain
  else
    die "Failed to determine the computer object state in LDAP"
  fi

  if [[ -n "${MD_EPHEMERAL_CA_BUNDLE:-}" ]]; then
    rm -f "$MD_EPHEMERAL_CA_BUNDLE"
    unset MD_EPHEMERAL_CA_BUNDLE CURL_CA_BUNDLE
  fi
}
