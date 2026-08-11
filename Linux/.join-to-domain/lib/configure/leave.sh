load_join_env() {
  load_join_state

  DOMAIN="${SAVED_DOMAIN:-}"
  REALM="${SAVED_REALM:-}"
  LDAP_BASE_DN="${SAVED_LDAP_BASE_DN:-}"
  LDAP_COMPUTER_OU="${SAVED_LDAP_COMPUTER_OU:-}"
  LDAP_GSSAPI_HOST="${SAVED_LDAP_GSSAPI_HOST:-${SAVED_DOMAIN:-}}"
  HOSTNAME="${SAVED_HOSTNAME:-}"
  FQDN="${SAVED_FQDN:-}"
  API_ADDRESS="${SAVED_API_ADDRESS:-${SAVED_API_HOST:-}}"
  API_HOST="$API_ADDRESS"
  CONTROLLER_FQDN="${SAVED_CONTROLLER_FQDN:-}"
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

  if [[ -n "${SAVED_API_ADDRESS:-${SAVED_API_HOST:-}}" ]]; then
    log "Saved API address: ${SAVED_API_ADDRESS:-${SAVED_API_HOST:-}}"
  else
    warn "Saved API host is unavailable; asking interactively"
  fi
}

validate_directory_credentials() {
  local leave_login leave_password leave_token detected_domain

  if [[ "${1:-load-state}" != "state-loaded" ]]; then
    load_join_env
  fi

  if [[ -n "${API_ADDRESS:-${API_HOST:-}}" ]]; then
    set_api_address "${API_ADDRESS:-${API_HOST:-}}" \
      || die "Invalid saved API address: ${API_ADDRESS:-${API_HOST:-}}"
  else
    prompt_api_address \
      || die "$(ui_text "Directory operation cancelled" "Операция с каталогом отменена")"
  fi

  read_tty leave_login "$(ui_text "Enter domain administrator login:" "Введите логин администратора домена:")"
  read_secret_tty leave_password "$(ui_text "Enter domain administrator password:" "Введите пароль администратора домена:")"

  [[ -n "$leave_login" && -n "$leave_password" ]] || die "Login and password must be filled"

  log "Checking API address: ${API_ADDRESS}"
  api_host_resolution_ok "$API_ADDRESS" \
    || die "$(ui_text "DNS resolution failed: ${API_ADDRESS}" "Не удалось разрешить имя через DNS: ${API_ADDRESS}")"

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

  log "Directory administrator credentials validated"
}

validate_leave_credentials() {
  validate_directory_credentials
  log "Credentials approved for explicit domain leave"
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

  if [[ "${MD_RESTORE_OPERATION_ONLY:-0}" -ne 1 ]]; then
    restore_networkmanager_dns_state || warn "NetworkManager DNS state was not fully restored"
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
  warn "$(ui_text "The previous join did not finish. Completing local rollback before retrying." "Предыдущее присоединение не завершилось. Перед новой попыткой завершается локальный откат.")"

  mkdir -p "${MD_STATE_DIR}"
  touch "${MD_ROLLBACK_MARKER}"

  if ! load_active_backup || ! validate_join_backup; then
    die "Active join backup is missing or corrupted"
  fi

  perform_local_rollback_cleanup

  # Keep the marker and backups if the process is interrupted. Remove the
  # transaction directory only after all local recovery steps have returned.
  rm -rf "${MD_STATE_DIR}"
  ok "$(ui_text "Incomplete join state was recovered" "Состояние незавершённого присоединения восстановлено")"
}

restart_after_leave() {
  systemctl daemon-reload || true
  systemctl restart systemd-resolved.service 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || true
  systemctl restart sshd.service 2>/dev/null || true
}

perform_authenticated_leave() {
  if ! load_active_backup || ! validate_join_backup; then
    die "Active join backup is missing or corrupted"
  fi

  log "Starting remote domain cleanup"
  delete_salt_minion_key_on_leave
  disable_computer_account_on_leave
  log "Remote domain cleanup step completed"

  log "Starting local leave cleanup"
  stop_domain_services
  remove_managed_files
  restore_backups || die "Original configuration could not be fully restored"
  cleanup_domain_state

  validate_restored_system || die "Restored PAM/NSS/SSH configuration validation failed"
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  rm -rf "$MD_STATE_DIR"

  restart_after_leave

  log "Local leave cleanup completed"
  ok "$(ui_text "MultiDirectory leave completed" "Выход из MultiDirectory завершён")"
  info "$(ui_text "System reboot is recommended" "Рекомендуется перезагрузить компьютер")"
}

leave_domain() {
  need_root
  setup_logging
  info "$(ui_text "Leaving MultiDirectory domain" "Выход из домена MultiDirectory")"

  load_os_release

  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd awk
  need_cmd tr

  if ! load_active_backup || ! validate_join_backup; then
    die "Active join backup is missing or corrupted"
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

  mkdir -p "${MD_STATE_DIR}"
  touch "${MD_ROLLBACK_MARKER}"

  perform_local_rollback_cleanup

  # A completed rollback must not look like an active managed join on the next
  # run. If the process is interrupted before this point, the marker remains
  # and the next normal Join action resumes recovery.
  printf 'RESTORED_AT=%q\n' "$(date --iso-8601=seconds)" >> "$MD_MANIFEST"
  rm -rf "${MD_STATE_DIR}"

  info "$(ui_text "Rollback completed" "Откат завершён")"
}

on_join_error() {
  local code="$1"
  local source_file="${2:-unknown}"
  local function_name="${3:-main}"
  local line="${4:-unknown}"
  local command="${5:-unknown}"

  trap - ERR INT TERM
  report_command_failure "$code" "$source_file" "$function_name" "$line" "$command"
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
