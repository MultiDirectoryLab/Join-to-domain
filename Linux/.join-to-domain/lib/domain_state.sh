add_domain_state_reason() {
  DETECTED_DOMAIN_REASONS+=("$1")
}

directory_has_entries() {
  local dir="$1"

  [[ -d "$dir" ]] || return 1
  find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

pending_transaction_manifest() {
  local pending_backup="${MD_PENDING_BACKUP:-${MD_STATE_DIR}/active-backup}"
  local backups_root="${MD_BACKUPS_ROOT:-${MD_ETC_DIR}/backups}"
  local backup

  [[ -r "$pending_backup" ]] || return 1
  IFS= read -r backup < "$pending_backup"
  case "$backup" in
    "$backups_root"/join-*|"$backups_root"/rejoin-*) ;;
    *) return 1 ;;
  esac
  [[ -r "$backup/manifest.env" ]] || return 1
  printf '%s\n' "$backup/manifest.env"
}

manifest_has_tracked_paths() {
  local manifest="${1:-}"

  if [[ -z "$manifest" ]]; then
    manifest="$(pending_transaction_manifest 2>/dev/null || true)"
  fi
  [[ -n "$manifest" ]] || manifest="${MD_MANIFEST:-}"
  [[ -f "$manifest" ]] || return 1

  # Support both the old path-per-line manifest and BACKUP_VERSION=1, where
  # tracked paths are stored as FILE_*_PATH=/absolute/path.
  grep -Eq '(^[[:space:]]*/[^[:space:]]+|^FILE_[A-Za-z0-9_]+_PATH=/)' "$manifest" 2>/dev/null
}

krb5_conf_looks_domain_managed() {
  [[ -f /etc/krb5.conf ]] || return 1

  if [[ -f "$MD_MANIFEST" ]] && grep -Fxq /etc/krb5.conf "$MD_MANIFEST" 2>/dev/null; then
    return 0
  fi

  grep -Eq '^[[:space:]]*dns_lookup_realm[[:space:]]*=[[:space:]]*false' /etc/krb5.conf 2>/dev/null &&
    grep -Eq '^[[:space:]]*ticket_lifetime[[:space:]]*=[[:space:]]*7d' /etc/krb5.conf 2>/dev/null &&
    grep -Eq '^[[:space:]]*renew_lifetime[[:space:]]*=[[:space:]]*14d' /etc/krb5.conf 2>/dev/null &&
    grep -Eq '^[[:space:]]*admin_server[[:space:]]*=' /etc/krb5.conf 2>/dev/null
}

sssd_conf_has_domain_block() {
  [[ -f /etc/sssd/sssd.conf ]] || return 1
  grep -Eq '^\[domain/[^]]+\]|MultiDirectory' /etc/sssd/sssd.conf 2>/dev/null
}

recoverable_incomplete_join_detected() {
  local rollback_marker="${MD_ROLLBACK_MARKER:-${MD_STATE_DIR}/rollback-in-progress}"
  local pending_backup="${MD_PENDING_BACKUP:-${MD_STATE_DIR}/active-backup}"
  local pending_manifest=""

  # active-backup is the authoritative marker for an interrupted Join or
  # Rejoin transaction. A completed operation removes it.
  pending_manifest="$(pending_transaction_manifest 2>/dev/null || true)"
  if [[ -n "$pending_manifest" ]] && manifest_has_tracked_paths "$pending_manifest"; then
    return 0
  fi
  # A malformed pointer must block a new transaction rather than be silently
  # overwritten. The recovery path will report that the backup is corrupted.
  [[ -e "$pending_backup" ]] && return 0

  # The marker alone is not enough: older versions can leave an empty marker
  # together with an empty manifest after a completed rollback. Recover only
  # when the manifest contains paths changed by the interrupted transaction.
  if [[ -f "$rollback_marker" ]] && manifest_has_tracked_paths; then
    return 0
  fi

  # Without a rollback marker, a saved join.env marks a completed managed
  # join. Never clean it up automatically from the normal Join action.
  if [[ -f "$MD_JOIN_ENV" ]]; then
    return 1
  fi

  # A blank manifest contains no changes to recover and must not block a new
  # join. This also handles an orphaned, empty rollback marker.
  if ! manifest_has_tracked_paths; then
    return 1
  fi
  if sssd_conf_has_domain_block; then
    return 1
  fi
  if [[ -f /etc/krb5.keytab ]]; then
    return 1
  fi
  if have_cmd realm && realm list 2>/dev/null | grep -q '^[^[:space:]]'; then
    return 1
  fi

  return 0
}

detect_domain_state() {
  local managed=0 partial=0 unmanaged_sssd=0 detected_manifest=""

  DETECTED_DOMAIN_STATE="not_joined"
  DETECTED_DOMAIN_REASONS=()

  if [[ -f "$MD_JOIN_ENV" ]]; then
    managed=1
    add_domain_state_reason "MultiDirectory join state found: ${MD_JOIN_ENV}"
  fi

  detected_manifest="$(pending_transaction_manifest 2>/dev/null || true)"
  [[ -n "$detected_manifest" ]] || detected_manifest="${MD_MANIFEST:-}"
  if manifest_has_tracked_paths "$detected_manifest"; then
    managed=1
    add_domain_state_reason "MultiDirectory manifest found: ${detected_manifest}"
  fi

  if [[ -f "${MD_ROLLBACK_MARKER:-${MD_STATE_DIR}/rollback-in-progress}" ]] && manifest_has_tracked_paths "$detected_manifest"; then
    partial=1
    add_domain_state_reason "MultiDirectory rollback marker found: ${MD_ROLLBACK_MARKER:-${MD_STATE_DIR}/rollback-in-progress}"
  fi

  if have_cmd realm && realm list 2>/dev/null | grep -q '^[^[:space:]]'; then
    partial=1
    add_domain_state_reason "realm reports configured domain membership"
  fi

  if sssd_conf_has_domain_block; then
    if [[ "$managed" -eq 1 ]]; then
      add_domain_state_reason "Managed SSSD domain configuration found: /etc/sssd/sssd.conf"
    else
      unmanaged_sssd=1
      add_domain_state_reason "Unmanaged SSSD domain configuration found: /etc/sssd/sssd.conf"
    fi
  fi

  if directory_has_entries /etc/sssd/conf.d; then
    partial=1
    add_domain_state_reason "SSSD snippets found: /etc/sssd/conf.d"
  fi

  if [[ -f /etc/krb5.keytab ]]; then
    partial=1
    add_domain_state_reason "Kerberos keytab found: /etc/krb5.keytab"
  fi

  if krb5_conf_looks_domain_managed; then
    partial=1
    add_domain_state_reason "Kerberos configuration found: /etc/krb5.conf"
  fi

  if [[ -f /etc/sudoers.d/domain-admins ]]; then
    partial=1
    add_domain_state_reason "Domain sudoers file found: /etc/sudoers.d/domain-admins"
  fi

  if [[ -f /etc/systemd/resolved.conf.d/MultiDirectory.conf ]]; then
    partial=1
    add_domain_state_reason "MultiDirectory DNS configuration found: /etc/systemd/resolved.conf.d/MultiDirectory.conf"
  fi

  if [[ -f /etc/ssh/sshd_config.d/ssh_md.conf ]]; then
    partial=1
    add_domain_state_reason "Domain SSH configuration found: /etc/ssh/sshd_config.d/ssh_md.conf"
  fi

  if [[ -f /etc/salt/minion.append ]]; then
    partial=1
    add_domain_state_reason "Salt minion append file found: /etc/salt/minion.append"
  fi

  [[ -f /etc/salt/minion_id ]] && add_domain_state_reason "Salt minion id found: /etc/salt/minion_id"

  if [[ -f "$SALT_PKG_MODULE_DST" ]]; then
    partial=1
    add_domain_state_reason "Salt pkg module override found: ${SALT_PKG_MODULE_DST}"
  fi

  if [[ "$managed" -eq 1 ]]; then
    DETECTED_DOMAIN_STATE="managed_join"
  elif [[ "$partial" -eq 1 ]]; then
    DETECTED_DOMAIN_STATE="partial_join"
  elif [[ "$unmanaged_sssd" -eq 1 ]]; then
    DETECTED_DOMAIN_STATE="unmanaged_sssd"
  fi

  return 0
}

detect_domain_config_state() {
  detect_domain_state
}

confirm_safe_leave() {
  local choice

  cat <<EOF

$(tr_text leave.title)
$(tr_text leave.description)
$(tr_text leave.keep)

1) $(tr_text leave.continue)
2) $(tr_text leave.cancel)
EOF

  while true; do
    printf '%s: ' "$(tr_text prompt.select)"
    read_clean_input choice || choice=""

    case "$choice" in
      1)
        return 0
        ;;
      2|"")
        return 1
        ;;
      *)
        warn "$(tr_text error.invalid_12)"
        ;;
    esac
  done
}
