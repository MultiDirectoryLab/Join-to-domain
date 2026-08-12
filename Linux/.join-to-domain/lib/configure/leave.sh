load_join_env() {
  load_join_state

  DOMAIN="${SAVED_DOMAIN:-}"
  REALM="${SAVED_REALM:-}"
  LDAP_BASE_DN="${SAVED_LDAP_BASE_DN:-}"
  LDAP_COMPUTER_OU="${SAVED_LDAP_COMPUTER_OU:-}"
  HOSTNAME="${SAVED_HOSTNAME:-}"
  FQDN="${SAVED_FQDN:-}"
  API_HOST="${SAVED_API_HOST:-}"
  WITH_SALT="${SAVED_WITH_SALT:-0}"
  EDITION="${SAVED_EDITION:-community}"
  SALT_MASTER="${SAVED_SALT_MASTER:-}"
  SALT_MINION_ID="${SAVED_SALT_MINION_ID:-}"
  COMPUTER_DN="${SAVED_COMPUTER_DN:-}"

  if [[ -n "${SAVED_DOMAIN:-}" ]]; then
    log "Saved domain: ${SAVED_DOMAIN}"
  else
    warn "Saved domain is unavailable; it will be detected after authentication"
  fi

  if [[ -n "${SAVED_API_HOST:-}" ]]; then
    log "Saved API host: ${SAVED_API_HOST}"
  else
    warn "Saved API host is unavailable; asking interactively"
  fi
}

validate_leave_credentials() {
  local leave_login leave_password leave_token detected_domain dns_input dns_servers
  local supplied_api_host=""

  if env_has_key API_HOST; then
    supplied_api_host="${API_HOST:-}"
    [[ -n "$supplied_api_host" ]] || die "API_HOST is empty in environment"
  fi

  if [[ "${1:-load-state}" != "state-loaded" ]]; then
    load_join_env
  fi
  [[ -z "$supplied_api_host" ]] || API_HOST="$supplied_api_host"

  while true; do
    if [[ -z "${API_HOST:-}" ]]; then
      read_tty API_HOST "$(ui_text "Enter MULTIDIRECTORY server IPv4 address or FQDN:" "Введите IPv4-адрес или FQDN сервера MULTIDIRECTORY:")"
    fi
    if [[ -z "${API_HOST}" ]]; then
      warn "$(ui_text "API host must be filled." "Адрес API не может быть пустым.")"
      continue
    fi
    if ! valid_api_host "${API_HOST}"; then
      warn "$(ui_text "Invalid server address. Enter an IPv4 address or FQDN." "Некорректный адрес сервера. Введите IPv4-адрес или FQDN.")"
      API_HOST=""
      continue
    fi
    break
  done

  read_tty leave_login "$(ui_text "Enter domain administrator login:" "Введите логин администратора домена:")"
  read_secret_tty leave_password "$(ui_text "Enter domain administrator password:" "Введите пароль администратора домена:")"

  [[ -n "$leave_login" && -n "$leave_password" ]] || die "Login and password must be filled"

  log "Checking API host address: ${API_HOST}"
  while ! api_host_resolution_ok "${API_HOST}"; do
    warn "$(ui_text "DNS resolution failed: ${API_HOST}" "Не удалось разрешить имя через DNS: ${API_HOST}")"
    read_tty dns_input "$(ui_text "Enter DNS server IP address:" "Введите IP-адрес DNS-сервера:")"
    dns_servers="$(normalize_dns_servers "${dns_input}" 2>/dev/null || true)"
    if [[ -z "${dns_servers}" ]]; then
      warn "$(ui_text "Invalid DNS server address." "Некорректный адрес DNS-сервера.")"
      continue
    fi
    md_set_resolv_first "${dns_servers}" || {
      warn "$(ui_text "Failed to configure DNS servers." "Не удалось настроить DNS-серверы.")"
      continue
    }
    MD_DNS_SERVER="$dns_servers"
    log "DNS servers configured: $(dns_servers_csv "${dns_servers}")"
  done

  activity_start "$(ui_text "Checking connection to the domain" "Проверка подключения к домену")"
  install_md_server_certificate

  log "Authenticating domain administrator"
  leave_token="$(api_auth_cookie "$leave_login" "$leave_password")"
  [[ -n "$leave_token" ]] || die "Failed to authenticate domain administrator"

  log "Detecting domain via RootDSE"
  detected_domain="$(api_rootdse_domain "$leave_token")"
  [[ -n "$detected_domain" ]] || die "Failed to detect domain via RootDSE"

  detected_domain="$(echo "$detected_domain" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "${SAVED_DOMAIN:-}" ]]; then
    SAVED_DOMAIN="$detected_domain"
    DOMAIN="$detected_domain"
  fi

  log "Saved domain: ${SAVED_DOMAIN}"
  log "Authenticated domain: ${detected_domain}"

  if [[ "$detected_domain" != "$SAVED_DOMAIN" ]]; then
    unset leave_password
    die "Domain mismatch. Saved domain is ${SAVED_DOMAIN}, but authenticated domain is ${detected_domain}"
  fi

  access_token="$leave_token"
  LOGIN="$leave_login"

  unset leave_password
  activity_stop

  log "Leave credentials validated"
}

start_services() {
  local services=(sssd ssh sshd)
  local sshd_bin

  systemctl daemon-reload || true

  sshd_bin="$(find_executable sshd 2>/dev/null || true)"
  if [[ -n "$sshd_bin" ]]; then
    "$sshd_bin" -t || die "Error in SSH daemon configuration"
  fi

  for svc in "${services[@]}"; do
    systemctl enable "${svc}.service" >/dev/null 2>&1 || true
    systemctl restart "${svc}.service" >/dev/null 2>&1 || true
  done

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    restart_salt_minion_or_die
    services+=(salt-minion)
  fi

  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
      log "ACTIVE: ${svc}"
    else
      warn "NOT ACTIVE: ${svc}"
      systemctl status "${svc}.service" --no-pager -l 2>/dev/null || true
    fi
  done
}

stop_domain_services() {
  systemctl stop sssd.service 2>/dev/null || true
  systemctl stop salt-minion.service 2>/dev/null || true
  systemctl disable salt-minion.service 2>/dev/null || true
}

remove_managed_files() {
  : # restore_one removes paths recorded as absent in the manifest.
}

restore_backups() {
  local managed_path failed=0

  while IFS= read -r managed_path; do
    managed_path="${managed_path#*=}"
    restore_one "$managed_path" || failed=1
  done < <(grep '^FILE_.*_PATH=' "$MD_MANIFEST")
  [[ "$failed" -eq 0 ]] || return 1

  if [[ "${MD_RESTORE_OPERATION_ONLY:-0}" -eq 1 ]]; then
    if [[ -n "${MD_OPERATION_NM_DNS_STATE:-}" ]]; then
      restore_networkmanager_dns_state "$MD_OPERATION_NM_DNS_STATE" \
        || warn "NetworkManager DNS state was not fully restored"
    fi
  else
    restore_networkmanager_dns_state "$MD_NM_DNS_STATE" || warn "NetworkManager DNS state was not fully restored"
    restore_authselect_state || warn "authselect state was not fully restored"
    restore_sssd_socket_state || warn "SSSD socket state was not fully restored"
  fi

  if have_cmd update-ca-certificates; then
    update-ca-certificates >/dev/null 2>&1 || true
  elif have_cmd update-ca-trust; then
    update-ca-trust extract >/dev/null 2>&1 || true
  fi
}

validate_join_backup() {
  local path key rel existed
  [[ -n "${MD_BACKUP_DIR:-}" && -d "$MD_BACKUP_DIR" && -r "$MD_MANIFEST" ]] || return 1
  case "$MD_BACKUP_DIR" in "$MD_BACKUPS_ROOT"/join-*|"$MD_BACKUPS_ROOT"/rejoin-*) ;; *) return 1 ;; esac
  grep -q '^BACKUP_VERSION=1$' "$MD_MANIFEST" || return 1
  while IFS= read -r path; do
    key="$(backup_key "$path")"
    existed="$(sed -n "s/^${key}_EXISTED=//p" "$MD_MANIFEST" | tail -n1)"
    [[ "$existed" == 0 || "$existed" == 1 ]] || return 1
    rel="${path#/}"
    if [[ "$existed" == 1 && ! -e "$MD_BACKUP_DIR/files/$rel" && ! -L "$MD_BACKUP_DIR/files/$rel" ]]; then
      return 1
    fi
  done < <(managed_join_paths | awk '!seen[$0]++')

  while IFS= read -r path; do
    path="${path#*=}"
    key="$(backup_key "$path")"
    existed="$(sed -n "s/^${key}_EXISTED=//p" "$MD_MANIFEST" | tail -n1)"
    rel="${path#/}"
    [[ "$existed" == 0 || "$existed" == 1 ]] || return 1
    [[ "$existed" == 0 || -e "$MD_BACKUP_DIR/files/$rel" || -L "$MD_BACKUP_DIR/files/$rel" ]] || return 1
  done < <(grep '^FILE_.*_PATH=' "$MD_MANIFEST")
}

validate_restored_system() {
  local pam_file sshd_bin
  for pam_file in /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-session /etc/pam.d/common-password; do
    [[ ! -e "$pam_file" ]] && continue
    [[ -s "$pam_file" ]] || { warn "PAM restore validation failed: $pam_file"; return 1; }
  done
  if [[ -f /etc/pam.d/common-auth ]] && ! grep -Eq 'pam_unix\.so|pam_localuser\.so' /etc/pam.d/common-auth; then
    warn "PAM restore validation failed: local authentication module missing"
    return 1
  fi
  if [[ -f /etc/nsswitch.conf ]]; then
    awk '$1 ~ /^(passwd|group):$/ && $0 ~ /(^|[[:space:]])files([[:space:]]|$)/ {ok[$1]=1} END {exit !(ok["passwd:"] && ok["group:"])}' /etc/nsswitch.conf || return 1
  fi
  sshd_bin="$(find_executable sshd 2>/dev/null || true)"
  [[ -z "$sshd_bin" ]] || "$sshd_bin" -t || return 1
}

cleanup_domain_state() {
  if md_backup_exists /etc/krb5.keytab; then
    log "Keeping restored Kerberos keytab backup"
  elif md_is_tracked /etc/krb5.keytab; then
    rm -f /etc/krb5.keytab
  else
    log "Keeping untracked Kerberos keytab"
  fi

  find "${MD_STATE_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'ktadd.*' -exec rm -rf -- {} + 2>/dev/null || true

  if [[ -f "${MD_JOIN_ENV}" || -f "${MD_ROLLBACK_MARKER}" ]]; then
    rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
  fi

  if md_backup_exists /etc/salt/pki/minion; then
    log "Keeping restored Salt minion key backup"
  elif md_is_tracked /etc/salt/pki/minion; then
    rm -rf /etc/salt/pki/minion/* 2>/dev/null || true
  else
    log "Keeping untracked Salt minion key pair"
  fi

  find /var/cache/salt/minion/extmods/modules -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
  find /var/cache/salt/minion/extmods -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
  find /etc/systemd/resolved.conf.d -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
}

perform_local_rollback_cleanup() {
  set +e

  stop_domain_services
  remove_managed_files
  restore_backups
  cleanup_domain_state
  restart_after_leave

  set -e
}

recover_incomplete_join_state() {
  local backup_kind

  warn "$(ui_text "The previous join did not finish. Completing local rollback before retrying." "Предыдущее присоединение не завершилось. Перед новой попыткой завершается локальный откат.")"
  activity_start "$(ui_text "Restoring local configuration" "Восстановление локальной конфигурации")"

  mkdir -p "${MD_STATE_DIR}"
  touch "${MD_ROLLBACK_MARKER}"

  if ! load_active_backup || ! validate_join_backup; then
    die "Active join backup is missing or corrupted"
  fi

  backup_kind="$(sed -n 's/^BACKUP_KIND=//p' "$MD_MANIFEST" | tail -n1)"
  case "$backup_kind" in
    rejoin)
      warn "$(ui_text "An interrupted Rejoin was found; restoring the configuration from immediately before Rejoin." "Обнаружен прерванный Rejoin; восстанавливается конфигурация непосредственно перед Rejoin.")"
      MD_RESTORE_OPERATION_ONLY=1
      perform_local_rollback_cleanup
      MD_RESTORE_OPERATION_ONLY=0
      printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
      rm -f "$MD_PENDING_BACKUP" "$MD_ROLLBACK_MARKER"
      MD_OPERATION_NM_DNS_STATE=""
      activity_stop
      ok "$(ui_text "Interrupted Rejoin state was recovered" "Состояние прерванного Rejoin восстановлено")"
      return 0
      ;;
    join) ;;
    *) die "Active backup has an invalid BACKUP_KIND: ${backup_kind:-empty}" ;;
  esac

  perform_local_rollback_cleanup

  # Keep the marker and backups if the process is interrupted. Remove the
  # transaction directory only after all local recovery steps have returned.
  rm -rf "${MD_STATE_DIR}"
  activity_stop
  ok "$(ui_text "Incomplete join state was recovered" "Состояние незавершённого присоединения восстановлено")"
}

restart_after_leave() {
  systemctl daemon-reload || true
  systemctl restart systemd-resolved.service 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || true
  systemctl restart sshd.service 2>/dev/null || true
}

perform_local_leave_cleanup() {
  log "Starting local leave cleanup"
  activity_start "$(ui_text "Restoring local configuration" "Восстановление локальной конфигурации")"
  stop_domain_services
  remove_managed_files
  restore_backups || die "Original configuration could not be fully restored"
  cleanup_domain_state

  validate_restored_system || die "Restored PAM/NSS/SSH configuration validation failed"
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  rm -rf "$MD_STATE_DIR"

  restart_after_leave

  log "Local leave cleanup completed"
  activity_stop
  if [[ "${MD_DOMAIN_SWITCH_ACTIVE:-0}" == "1" ]]; then
    ok "$(ui_text "Old local domain membership removed" "Локальное членство в старом домене удалено")"
  else
    user_ok "$(ui_text "MultiDirectory leave completed" "Выход из MultiDirectory завершён")"
    user_info "$(ui_text "System reboot is recommended" "Рекомендуется перезагрузить компьютер")"
  fi
}

perform_authenticated_leave() {
  if ! load_active_backup || ! validate_join_backup; then
    die "Active join backup is missing or corrupted"
  fi

  activity_start "$(ui_text "Removing the computer from the domain" "Удаление компьютера из домена")"
  log "Starting remote domain cleanup"
  delete_salt_minion_key_on_leave
  disable_computer_account_on_leave
  log "Remote domain cleanup step completed"

  perform_local_leave_cleanup
}

leave_domain_locally_for_switch() {
  need_root
  setup_logging
  info "$(ui_text "Removing local membership in the unavailable old domain" "Удаление локального членства в недоступном старом домене")"
  load_os_release

  if recoverable_incomplete_join_detected; then
    recover_incomplete_join_state
  fi

  need_cmd awk
  need_cmd sed
  need_cmd tr

  if ! load_active_backup || ! validate_join_backup; then
    die "$(ui_text "The pre-join backup is missing or corrupted; local domain switch cannot continue safely" "Исходная резервная копия отсутствует или повреждена; безопасный локальный переход в другой домен невозможен")"
  fi
  ok "$(ui_text "Backup validated" "Резервная копия проверена")"
  log "Old-domain LDAP computer and Salt objects remain on the old server"

  perform_local_leave_cleanup
}

leave_domain() {
  need_root
  setup_logging
  user_info "$(ui_text "Leaving MultiDirectory domain" "Выход из домена MultiDirectory")"

  load_os_release

  if recoverable_incomplete_join_detected; then
    recover_incomplete_join_state
  fi

  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd awk
  need_cmd tr

  if ! load_active_backup || ! validate_join_backup; then
    die "$(ui_text "The pre-join backup is missing or corrupted; safe Leave cannot continue" "Исходная резервная копия отсутствует или повреждена; безопасный выход из домена невозможен")"
  fi
  ok "$(ui_text "Backup validated" "Резервная копия проверена")"

  info "$(ui_text "Authenticating directory administrator" "Проверка аутентификации администратора каталога")"
  validate_leave_credentials
  ok "$(ui_text "Directory administrator authentication succeeded" "Аутентификация администратора каталога выполнена успешно")"

  perform_authenticated_leave
}

rollback_local_changes() {
  local code="$1"

  warn "$(ui_text "Join failed with exit code ${code}" "Присоединение завершилось ошибкой с кодом ${code}")"
  warn "$(ui_text "Rolling back local configuration changes" "Выполняется откат локальных изменений")"
  warn "$(ui_text "Server-side objects created via API are not removed by local rollback" "Объекты, созданные на сервере через API, не удаляются локальным откатом")"
  activity_start "$(ui_text "Restoring local configuration" "Восстановление локальной конфигурации")"

  mkdir -p "${MD_STATE_DIR}"
  touch "${MD_ROLLBACK_MARKER}"

  perform_local_rollback_cleanup

  # A completed rollback must not look like an active managed join on the next
  # run. If the process is interrupted before this point, the marker remains
  # and the next normal Join action resumes recovery.
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  rm -rf "${MD_STATE_DIR}"

  activity_stop
  user_ok "$(ui_text "Rollback completed" "Откат завершён")"
}

on_join_error() {
  local code=$?

  trap - ERR INT TERM
  MD_JOIN_ROLLBACK_ACTIVE=0

  rollback_local_changes "$code"

  exit "$code"
}

on_join_signal() {
  local code=130

  trap - ERR INT TERM
  MD_JOIN_ROLLBACK_ACTIVE=0

  warn "$(ui_text "Domain join was interrupted" "Присоединение к домену прервано")"
  rollback_local_changes "$code"

  exit "$code"
}

validate_internal_modules() {
  local helper
  local -a required_helpers=(
    create_join_backup md_backup_once restore_one rollback_local_changes
    build_sssd_conf install_pam_config install_nsswitch_config
    validate_sssd_config validate_no_password_based_sssd_auth
  )

  if is_astra_se; then
    required_helpers+=(
      astra_parsec_mswitch_available install_astra_parsec_sssd_packages
      write_astra_parsec_sssd_conf validate_astra_parsec_sssd_config_or_rollback
      configure_astra_parsec_mswitch restart_astra_parsec_sssd_or_rollback
    )
  fi

  info "$(ui_text "Validating internal modules" "Проверка внутренних модулей")"
  for helper in "${required_helpers[@]}"; do
    declare -F "$helper" >/dev/null 2>&1 || die "Required internal helper is not loaded: ${helper}"
  done
  ok "$(ui_text "Internal modules loaded" "Внутренние модули загружены")"
}

preflight() {
  need_root
  setup_logging
  load_os_release
  check_system_capabilities

  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd file
  need_cmd sed
  need_cmd awk
  need_cmd tr
  need_cmd hostname
  need_cmd klist
  need_cmd kinit
  need_cmd ldapwhoami
  need_cmd sort

  validate_internal_modules

  normalize_files_eol
}
