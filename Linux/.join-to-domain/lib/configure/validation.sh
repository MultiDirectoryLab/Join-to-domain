validate_api_host_resolution() {
  log "Checking DNS resolution: ${API_HOST}"
  getent hosts "${API_HOST}" >/dev/null || die "DNS resolution failed: ${API_HOST}"
  log "DNS resolution OK: ${API_HOST}"
}

validate_salt_host_resolution() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || {
    log "Community edition: salt DNS check skipped"
    return 0
  }

  [[ -n "${SALT_MASTER:-}" ]] || {
    log "Salt master is not known yet, salt DNS check skipped"
    return 0
  }

  log "Checking DNS resolution: ${SALT_MASTER}"
  getent hosts "${SALT_MASTER}" >/dev/null || die "DNS resolution failed: ${SALT_MASTER}"
  log "DNS resolution OK: ${SALT_MASTER}"
}

validate_initial_hosts_resolution() {
  validate_api_host_resolution
}

validate_admin_credentials() {
  log "Authenticating domain administrator via API"

  access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"
  [[ -n "${access_token}" ]] || die "Failed to authenticate domain administrator"

  log "Domain administrator credentials are valid"
}

discover_and_validate_domain() {
  log "Detecting domain via RootDSE"

  DOMAIN="$(api_rootdse_domain "${access_token}")"
  [[ -n "${DOMAIN}" ]] || die "Failed to detect DOMAIN via RootDSE"
  DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

  log "Detected domain: ${DOMAIN}"

  log "Getting defaultNamingContext"

  LDAP_BASE_DN="$(api_rootdse_default_nc "${access_token}")"
  [[ -n "${LDAP_BASE_DN}" ]] || die "Failed to get defaultNamingContext"

  log "Detected defaultNamingContext: ${LDAP_BASE_DN}"

  REALM="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"
  KDC="$DOMAIN"
  KADMIN="$DOMAIN"
  URI="ldap://${DOMAIN}"
  LDAP_SEARCH_BASE="$LDAP_BASE_DN"
  LDAP_USER_BASE="$LDAP_BASE_DN"
  LDAP_GROUP_BASE="$LDAP_BASE_DN"
  LDAP_COMPUTER_OU="cn=computers,${LDAP_BASE_DN}"

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    SALT_MASTER="salt.${DOMAIN}"
  fi
}

validate_sudoers() {
  if have_cmd visudo; then
    visudo -cf /etc/sudoers || die "sudoers validation failed"
  else
    warn "visudo not found, sudoers validation skipped"
  fi
}

validate_sssd_config() {
  if have_cmd sssctl; then
    sssctl config-check || die "SSSD configuration is invalid"
  else
    warn "sssctl not found, SSSD config validation skipped"
  fi
}

validate_no_password_based_sssd_auth() {
  local forbidden='ldap_default_bind_dn|ldap_default_authtok|ldap_default_authtok_type|__SSSD_|__BIND_DN__|__PASSWORD__'

  [[ -f /etc/sssd/sssd.conf ]] || return 0

  if grep -En "$forbidden" /etc/sssd/sssd.conf >/tmp/md-sssd-password-auth.matches 2>/dev/null; then
    warn "Forbidden password-based SSSD settings found:"
    cat /tmp/md-sssd-password-auth.matches || true
    die "SSSD must use Kerberos GSSAPI with /etc/krb5.keytab only"
  fi
}

disable_sssd_socket_activation_if_needed() {
  local services_line unit disabled_count=0
  local sockets=(
    sssd-nss.socket
    sssd-pam.socket
    sssd-pam-priv.socket
    sssd-ssh.socket
    sssd-sudo.socket
  )

  [[ -f /etc/sssd/sssd.conf ]] || return 0
  have_cmd systemctl || return 0

  services_line="$(
    awk '
      BEGIN { in_sssd=0 }
      /^\[sssd\]/ { in_sssd=1; next }
      /^\[/ { in_sssd=0 }
      in_sssd && /^[[:space:]]*services[[:space:]]*=/ { print; exit }
    ' /etc/sssd/sssd.conf 2>/dev/null || true
  )"

  [[ -n "$services_line" ]] || {
    log "SSSD services line not found, socket activation will not be changed"
    return 0
  }

  if ! echo "$services_line" | grep -Eq '(^|[,=[:space:]])(nss|pam|ssh|sudo)([,[:space:]]|$)'; then
    log "SSSD services line does not contain nss/pam/ssh/sudo, socket activation will not be changed"
    return 0
  fi

  log "SSSD services are configured in /etc/sssd/sssd.conf; disabling conflicting socket activation units if present"

  systemctl daemon-reload >/dev/null 2>&1 || true

  for unit in "${sockets[@]}"; do
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^${unit}"; then
      systemctl stop "$unit" 2>/dev/null || true
      systemctl disable "$unit" 2>/dev/null || true
      systemctl mask "$unit" 2>/dev/null || true
      disabled_count=$((disabled_count + 1))
    fi
  done

  if [[ "$disabled_count" -gt 0 ]]; then
    log "Disabled and masked conflicting SSSD socket activation units: ${disabled_count}"
  fi
}
