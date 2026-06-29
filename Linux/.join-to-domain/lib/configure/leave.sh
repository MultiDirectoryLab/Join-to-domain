load_join_env() {
  [[ -f "$MD_JOIN_ENV" ]] || die "Join state file not found: ${MD_JOIN_ENV}"

  # shellcheck disable=SC1090
  . "$MD_JOIN_ENV"

  [[ -n "${DOMAIN:-}" ]] || die "DOMAIN is missing in ${MD_JOIN_ENV}"
  [[ -n "${API_HOST:-}" ]] || die "API_HOST is missing in ${MD_JOIN_ENV}"

  SAVED_DOMAIN="$DOMAIN"
  SAVED_API_HOST="$API_HOST"

  SAVED_DOMAIN="$(echo "$SAVED_DOMAIN" | tr '[:upper:]' '[:lower:]')"

  log "Saved domain: ${SAVED_DOMAIN}"
  log "Saved API host: ${SAVED_API_HOST}"
}

validate_leave_credentials() {
  local leave_login leave_password leave_token detected_domain

  load_join_env

  read_tty leave_login "Enter domain administrator login:"
  read_secret_tty leave_password "Enter domain administrator password:"

  [[ -n "$leave_login" && -n "$leave_password" ]] || die "Login and password must be filled"

  API_HOST="$SAVED_API_HOST"

  log "Checking DNS resolution: ${API_HOST}"
  getent hosts "${API_HOST}" >/dev/null || die "DNS resolution failed: ${API_HOST}"

  log "Authenticating domain administrator"
  leave_token="$(api_auth_cookie "$leave_login" "$leave_password")"
  [[ -n "$leave_token" ]] || die "Failed to authenticate domain administrator"

  log "Detecting domain via RootDSE"
  detected_domain="$(api_rootdse_domain "$leave_token")"
  [[ -n "$detected_domain" ]] || die "Failed to detect domain via RootDSE"

  detected_domain="$(echo "$detected_domain" | tr '[:upper:]' '[:lower:]')"

  log "Saved domain: ${SAVED_DOMAIN}"
  log "Authenticated domain: ${detected_domain}"

  if [[ "$detected_domain" != "$SAVED_DOMAIN" ]]; then
    unset leave_password
    die "Domain mismatch. Saved domain is ${SAVED_DOMAIN}, but authenticated domain is ${detected_domain}"
  fi

  access_token="$leave_token"
  LOGIN="$leave_login"

  unset leave_password

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
  if [[ ! -f "$MD_MANIFEST" ]]; then
    warn "Manifest not found: ${MD_MANIFEST}"
    return 0
  fi

  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" == "/" ]] && continue
    [[ "$p" == "$MD_MANIFEST" ]] && continue

    if [[ -L "$p" || -f "$p" ]]; then
      rm -f "$p"
      log "Removed managed file: $p"
    fi
  done < "$MD_MANIFEST"
}

restore_backups() {
  restore_one /etc/krb5.conf
  restore_one /etc/nsswitch.conf
  restore_one /etc/ssh/sshd_config.d/ssh_md.conf
  restore_one /etc/sssd/sssd.conf
  restore_one /etc/sssd/conf.d
  restore_one /etc/hostname
  restore_one /etc/hosts
  restore_one /etc/resolv.conf

  restore_one /etc/pam.d/system-auth
  restore_one /etc/pam.d/su
  restore_one /etc/pam.d/sshd
  restore_one /etc/pam.d/gdm-password
  restore_one /etc/pam.d/login
  restore_one /etc/pam.d/common-login
  restore_one /etc/pam.d/common-auth
  restore_one /etc/pam.d/common-account
  restore_one /etc/pam.d/common-session
  restore_one /etc/pam.d/common-password

  restore_one /etc/salt/minion
  restore_one /etc/salt/minion_id
  restore_one /etc/salt/pki/minion
  restore_one "$SALT_PKG_MODULE_DST"
}

cleanup_domain_state() {
  rm -f /etc/krb5.keytab

  if [[ -f "${MD_JOIN_ENV}" || -f "${MD_ROLLBACK_MARKER}" ]]; then
    rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
  fi

  if md_backup_exists /etc/salt/pki/minion; then
    log "Keeping restored Salt minion key backup"
  else
    rm -rf /etc/salt/pki/minion/* 2>/dev/null || true
  fi

  find /var/cache/salt/minion/extmods/modules -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
  find /var/cache/salt/minion/extmods -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
  find /etc/systemd/resolved.conf.d -mindepth 0 -maxdepth 0 -type d -empty -delete 2>/dev/null || true
}

restart_after_leave() {
  systemctl daemon-reload || true
  systemctl restart systemd-resolved.service 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || true
  systemctl restart sshd.service 2>/dev/null || true
}

leave_domain() {
  need_root
  setup_logging
  md_init_state

  warn "Leaving MultiDirectory domain"

  load_os_release

  need_cmd curl
  need_cmd jq
  need_cmd getent
  need_cmd awk
  need_cmd tr

  validate_leave_credentials
  log "Starting optional remote LDAP cleanup"
  delete_salt_minion_key_on_leave
  disable_computer_account_on_leave
  log "Remote LDAP cleanup step completed"

  log "Starting local leave cleanup"
  stop_domain_services
  remove_managed_files
  restore_backups
  cleanup_domain_state

  rm -rf "$MD_ETC_DIR"

  restart_after_leave

  log "Local leave cleanup completed"
  log "MultiDirectory leave completed"
  warn "System reboot is recommended"
}

rollback_local_changes() {
  local code="$1"

  warn "Join failed with exit code ${code}"
  warn "Rolling back local configuration changes"
  warn "Server-side objects created via API are not removed by local rollback"

  mkdir -p "${MD_STATE_DIR}"
  touch "${MD_ROLLBACK_MARKER}"

  set +e

  stop_domain_services
  remove_managed_files
  restore_backups
  cleanup_domain_state
  restart_after_leave

  rm -f "${MD_ROLLBACK_MARKER}"

  set -e

  warn "Rollback completed"
}

on_join_error() {
  local code=$?

  trap - ERR

  rollback_local_changes "$code"

  exit "$code"
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

  normalize_files_eol
}
