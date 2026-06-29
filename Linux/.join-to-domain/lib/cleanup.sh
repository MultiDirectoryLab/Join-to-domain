need_root_for_cleanup() {
  if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
    error "Domain cleanup requires root. Run: sudo $0"
    return 1
  fi

  return 0
}

safe_remove_path() {
  local path="$1"

  [[ -n "$path" && "$path" != "/" ]] || return 0
  [[ -e "$path" || -L "$path" ]] || {
    cleanup_log "Skipped absent path: ${path}"
    return 0
  }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: remove ${path}"
    cleanup_log "Dry-run remove: ${path}"
    return 0
  fi

  if rm -rf -- "$path"; then
    cleanup_log "Removed: ${path}"
    return 0
  fi

  error "Failed to remove: ${path}"
  cleanup_log "Failed to remove: ${path}"
  return 1
}

stop_domain_services_for_cleanup() {
  local service

  if ! have_cmd systemctl; then
    warn "systemctl not found, skipping service stop"
    cleanup_log "systemctl not found, service stop skipped"
    return 0
  fi

  for service in sssd.service salt-minion.service; do
    if systemctl list-unit-files "$service" >/dev/null 2>&1 || systemctl status "$service" >/dev/null 2>&1; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run: stop ${service}"
        cleanup_log "Dry-run stop service: ${service}"
      else
        systemctl stop "$service" 2>/dev/null || true
        cleanup_log "Stopped service if active: ${service}"
      fi
    else
      cleanup_log "Service not present, skipped: ${service}"
    fi
  done
}

cleanup_domain_runtime_state() {
  local path failed=0
  local domain_paths=(
    /etc/krb5.keytab
    /etc/sudoers.d/domain-admins
    /etc/systemd/resolved.conf.d/MultiDirectory.conf
    /etc/salt/minion.append
    "$MD_JOIN_ENV"
    "${MD_STATE_DIR}/rollback-in-progress"
    "$MD_MANIFEST"
    "$SALT_PKG_MODULE_DST"
  )

  for path in "${domain_paths[@]}"; do
    safe_remove_path "$path" || failed=1
  done

  return "$failed"
}

cleanup_sssd_cache() {
  local cache_dir

  for cache_dir in /var/lib/sss/db /var/lib/sss/mc; do
    [[ -d "$cache_dir" ]] || {
      cleanup_log "SSSD cache directory absent: ${cache_dir}"
      continue
    }

    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "Dry-run: clear ${cache_dir}"
      cleanup_log "Dry-run clear SSSD cache: ${cache_dir}"
      continue
    fi

    rm -rf -- "${cache_dir:?}/"* 2>/dev/null || true
    cleanup_log "Cleared SSSD cache: ${cache_dir}"
  done
}

validate_pam_safety() {
  local failed=0

  PAM_SAFETY_OK=0

  if [[ -f /etc/pam.d/common-auth ]] && ! grep -Eq '^[^#]*pam_unix\.so' /etc/pam.d/common-auth 2>/dev/null; then
    error "PAM safety check failed: /etc/pam.d/common-auth lacks pam_unix.so"
    cleanup_log "PAM validation failed: common-auth lacks pam_unix.so"
    failed=1
  fi

  if [[ -f /etc/pam.d/common-account ]] && ! grep -Eq '^[^#]*(pam_unix\.so|pam_localuser\.so|pam_permit\.so)' /etc/pam.d/common-account 2>/dev/null; then
    error "PAM safety check failed: /etc/pam.d/common-account lacks a local account path"
    cleanup_log "PAM validation failed: common-account lacks local account path"
    failed=1
  fi

  if [[ -f /etc/pam.d/common-session ]] && ! grep -Eq '^[^#]*(pam_unix\.so|pam_systemd\.so|pam_permit\.so)' /etc/pam.d/common-session 2>/dev/null; then
    error "PAM safety check failed: /etc/pam.d/common-session has no recognizable local session path"
    cleanup_log "PAM validation failed: common-session lacks local session path"
    failed=1
  fi

  if [[ -f /etc/pam.d/common-password ]] && ! grep -Eq '^[^#]*pam_unix\.so' /etc/pam.d/common-password 2>/dev/null; then
    error "PAM safety check failed: /etc/pam.d/common-password lacks pam_unix.so"
    cleanup_log "PAM validation failed: common-password lacks pam_unix.so"
    failed=1
  fi

  if [[ -f /etc/pam.d/system-auth ]] && ! grep -Eq '^[^#]*pam_unix\.so' /etc/pam.d/system-auth 2>/dev/null; then
    error "PAM safety check failed: /etc/pam.d/system-auth lacks pam_unix.so"
    cleanup_log "PAM validation failed: system-auth lacks pam_unix.so"
    failed=1
  fi

  if [[ "$failed" -eq 0 ]]; then
    PAM_SAFETY_OK=1
    cleanup_log "PAM validation result: safe"
    return 0
  fi

  cleanup_log "PAM validation result: unsafe"
  return 1
}

timestamped_backup_path() {
  local path="$1"
  printf '%s.disabled.%s' "$path" "$(date '+%Y%m%d%H%M%S')"
}

cleanup_sssd_domain_state() {
  local backup

  if [[ ! -f /etc/sssd/sssd.conf ]]; then
    cleanup_log "SSSD cleanup result: /etc/sssd/sssd.conf absent"
    return 0
  fi

  if ! sssd_conf_has_domain_block; then
    cleanup_log "SSSD cleanup result: existing config kept, no MultiDirectory domain block detected"
    return 0
  fi

  if [[ "$DETECTED_DOMAIN_STATE" == "unmanaged_sssd" ]]; then
    warn "Unmanaged SSSD domain config was found; keeping /etc/sssd/sssd.conf unchanged"
    cleanup_log "SSSD cleanup result: unmanaged config kept"
    return 0
  fi

  if [[ "$PAM_SAFETY_OK" -ne 1 ]]; then
    warn "Keeping /etc/sssd/sssd.conf because PAM safety validation failed"
    cleanup_log "SSSD cleanup result: config kept because PAM is unsafe without SSSD"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: move /etc/sssd/sssd.conf to timestamped backup"
    cleanup_log "Dry-run SSSD cleanup: would move /etc/sssd/sssd.conf"
    return 0
  fi

  backup="$(timestamped_backup_path /etc/sssd/sssd.conf)"
  if mv /etc/sssd/sssd.conf "$backup"; then
    cleanup_log "SSSD cleanup result: moved /etc/sssd/sssd.conf to ${backup}"
    return 0
  fi

  error "Failed to move /etc/sssd/sssd.conf to backup"
  cleanup_log "SSSD cleanup result: failed to move /etc/sssd/sssd.conf"
  return 1
}

validate_ssh_safety() {
  local sshd_bin

  sshd_bin="$(find_executable sshd 2>/dev/null || true)"

  if [[ -z "$sshd_bin" ]]; then
    cleanup_log "SSH validation result: sshd not found, skipped"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: validate SSH configuration"
    cleanup_log "Dry-run SSH validation"
    return 0
  fi

  if "$sshd_bin" -t; then
    cleanup_log "SSH validation result: safe"
    return 0
  fi

  error "SSH safety check failed: SSH daemon reported an invalid configuration"
  cleanup_log "SSH validation result: failed"
  return 1
}

cleanup_ssh_domain_state() {
  local ssh_md=/etc/ssh/sshd_config.d/ssh_md.conf
  local backup

  [[ -e "$ssh_md" || -L "$ssh_md" ]] || {
    cleanup_log "SSH cleanup result: domain SSH snippet absent"
    return 0
  }

  validate_ssh_safety || {
    warn "Keeping domain SSH snippet because current SSH configuration is invalid"
    cleanup_log "SSH cleanup result: kept before-change invalid config"
    return 0
  }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: remove ${ssh_md} after sshd validation"
    cleanup_log "Dry-run SSH cleanup: remove ${ssh_md}"
    return 0
  fi

  backup="$(timestamped_backup_path "$ssh_md")"
  if ! mv "$ssh_md" "$backup"; then
    error "Failed to move ${ssh_md} to backup"
    cleanup_log "SSH cleanup result: failed to move ${ssh_md}"
    return 1
  fi

  if validate_ssh_safety; then
    cleanup_log "SSH cleanup result: moved ${ssh_md} to ${backup}"
    return 0
  fi

  mv "$backup" "$ssh_md" 2>/dev/null || true
  error "SSH config failed after removing domain snippet; restored ${ssh_md}"
  cleanup_log "SSH cleanup result: restored ${ssh_md} after validation failure"
  return 1
}

cleanup_empty_domain_dirs() {
  local dir
  local dirs=(
    /var/cache/salt/minion/extmods/modules
    /var/cache/salt/minion/extmods
    /etc/systemd/resolved.conf.d
    "$MD_STATE_DIR"
    "$MD_ETC_DIR"
  )

  [[ "$DRY_RUN" -eq 1 ]] && return 0

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    rmdir "$dir" 2>/dev/null || true
  done
}

reload_services_after_cleanup() {
  if ! have_cmd systemctl; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run: reload affected services"
    cleanup_log "Dry-run service reload after cleanup"
    return 0
  fi

  systemctl daemon-reload 2>/dev/null || true
  systemctl restart systemd-resolved.service 2>/dev/null || true
  if validate_ssh_safety; then
    systemctl reload ssh.service 2>/dev/null || systemctl restart ssh.service 2>/dev/null || true
    systemctl reload sshd.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
  else
    warn "SSH reload skipped because sshd validation failed"
  fi
  cleanup_log "Reloaded affected services after cleanup"
}

cleanup_optional_remote_computer_object() {
  cleanup_log "Remote LDAP cleanup result: optional cleanup skipped by safe rejoin leave"
  return 0
}

safe_leave_domain() {
  local failed=0

  need_root_for_cleanup || return 1
  cleanup_log "Safe leave started"
  cleanup_log "Detected state: ${DETECTED_DOMAIN_STATE}"
  cleanup_log "Files intentionally kept: /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-session /etc/pam.d/common-password /etc/nsswitch.conf /etc/hosts /etc/hostname /etc/ssh/sshd_config"

  validate_pam_safety || true
  validate_ssh_safety || true
  cleanup_optional_remote_computer_object

  stop_domain_services_for_cleanup
  cleanup_domain_runtime_state || failed=1
  cleanup_sssd_domain_state || failed=1
  cleanup_ssh_domain_state || failed=1
  cleanup_sssd_cache
  cleanup_empty_domain_dirs
  reload_services_after_cleanup

  if [[ "$failed" -ne 0 ]]; then
    error "Safe domain leave completed with errors"
    cleanup_log "Final leave result: completed with errors"
    return 1
  fi

  info "Safe MultiDirectory domain leave completed"
  warn "System reboot is recommended"
  cleanup_log "Final leave result: success"
  return 0
}

