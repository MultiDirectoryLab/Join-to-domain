add_domain_state_reason() {
  DETECTED_DOMAIN_REASONS+=("$1")
}

directory_has_entries() {
  local dir="$1"

  [[ -d "$dir" ]] || return 1
  find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
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

  # This marker is created before rollback starts and is removed only after
  # local restoration has completed. Its presence makes recovery unambiguous.
  if [[ -f "$rollback_marker" ]]; then
    return 0
  fi

  # Without a rollback marker, a saved join.env marks a completed managed
  # join. Never clean it up automatically from the normal Join action.
  if [[ -f "$MD_JOIN_ENV" ]]; then
    return 1
  fi

  # Older versions removed the marker but left an empty transaction manifest.
  # Recover that case only when there are no strong signs of a real join.
  if [[ ! -f "$MD_MANIFEST" ]]; then
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
  local managed=0 partial=0 unmanaged_sssd=0

  DETECTED_DOMAIN_STATE="not_joined"
  DETECTED_DOMAIN_REASONS=()

  if [[ -f "$MD_JOIN_ENV" ]]; then
    managed=1
    add_domain_state_reason "MultiDirectory join state found: ${MD_JOIN_ENV}"
  fi

  if [[ -f "$MD_MANIFEST" ]]; then
    managed=1
    add_domain_state_reason "MultiDirectory manifest found: ${MD_MANIFEST}"
  fi

  if [[ -f "${MD_ROLLBACK_MARKER:-${MD_STATE_DIR}/rollback-in-progress}" ]]; then
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
