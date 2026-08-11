validate_api_host_resolution() {
  if valid_ipv4_address "${API_ADDRESS}"; then
    log "API address is an IPv4 address; DNS resolution skipped: ${API_ADDRESS}"
    return 0
  fi

  log "Checking DNS resolution: ${API_ADDRESS}"
  api_host_resolution_ok "${API_ADDRESS}" || die "DNS resolution failed: ${API_ADDRESS}"
  log "DNS resolution OK: ${API_ADDRESS}"
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

  if ! access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"; then
    die "$(ui_text "Failed to authenticate domain administrator. Check the login, password, and API log." "Не удалось аутентифицировать администратора домена. Проверьте логин, пароль и журнал API.")"
  fi
  [[ -n "${access_token}" ]] || die "$(ui_text "Authentication did not return a session cookie" "Аутентификация не вернула cookie сессии")"

  if ! api_validate_session "${access_token}"; then
    unset access_token
    die "$(ui_text "The API rejected the administrator session. Check the login and password." "API отклонил сессию администратора. Проверьте логин и пароль.")"
  fi

  log "Domain administrator credentials are valid"
}

discover_and_validate_domain() {
  local rootdse_response="" rootdse_dns_host=""

  log "Detecting domain via RootDSE"

  if ! rootdse_response="$(api_rootdse_response "${access_token}")"; then
    die "$(ui_text "RootDSE API request failed. See the detailed response in ${LOG_FILE}" "Ошибка запроса RootDSE через API. Подробный ответ записан в ${LOG_FILE}")"
  fi

  LDAP_BASE_DN="$(printf '%s' "$rootdse_response" | api_response_attribute "defaultNamingContext")"
  [[ -n "$LDAP_BASE_DN" ]] || LDAP_BASE_DN="$(printf '%s' "$rootdse_response" | api_response_attribute "rootDomainNamingContext")"
  [[ -n "$LDAP_BASE_DN" ]] || LDAP_BASE_DN="$(printf '%s' "$rootdse_response" | api_response_attribute "namingContexts")"
  DOMAIN="$(printf '%s' "$LDAP_BASE_DN" | dn_to_domain)"
  [[ -n "$DOMAIN" ]] || DOMAIN="$(printf '%s' "$rootdse_response" | api_response_attribute "dnsDomainName")"
  [[ -n "$DOMAIN" ]] || DOMAIN="$(printf '%s' "$rootdse_response" | api_response_attribute "dnsForestName")"
  [[ -n "$DOMAIN" ]] || DOMAIN="$(printf '%s' "$rootdse_response" | api_response_attribute "dnsHostName")"

  [[ -n "$DOMAIN" ]] || die "$(ui_text "RootDSE response does not contain a domain or naming context. See ${LOG_FILE}" "Ответ RootDSE не содержит домен или контекст именования. Подробности записаны в ${LOG_FILE}")"
  [[ -n "$LDAP_BASE_DN" ]] || die "$(ui_text "RootDSE response does not contain defaultNamingContext, rootDomainNamingContext, or namingContexts. See ${LOG_FILE}" "Ответ RootDSE не содержит defaultNamingContext, rootDomainNamingContext или namingContexts. Подробности записаны в ${LOG_FILE}")"

  DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
  rootdse_dns_host="$(printf '%s' "$rootdse_response" | api_response_attribute "dnsHostName")"

  log "Detected domain: ${DOMAIN}"
  log "Detected defaultNamingContext: ${LDAP_BASE_DN}"

  info "$(ui_text "Domain detected: ${DOMAIN}" "Обнаружен домен: ${DOMAIN}")"
  info "$(ui_text "Detecting the controller name" "Определение имени контроллера")"
  discover_controller_fqdn "$rootdse_dns_host"
  ok "$(ui_text "MultiDirectory controller: ${CONTROLLER_FQDN}" "Контроллер MultiDirectory: ${CONTROLLER_FQDN}")"
  log "Controller discovery completed"
  log "Bootstrap API address: ${API_ADDRESS}"
  log "Canonical controller: ${CONTROLLER_FQDN}"
  log "API session remains on bootstrap address ${API_ADDRESS}; endpoint and cookie context are unchanged"

  if valid_ipv4_address "$API_ADDRESS"; then
    if controller_fqdn_resolves_to_address "$CONTROLLER_FQDN" "$API_ADDRESS"; then
      log "Controller DNS verification succeeded: ${CONTROLLER_FQDN} -> ${API_ADDRESS}"
    else
      warn "$(ui_text "Controller ${CONTROLLER_FQDN} was discovered by MultiDirectory, but local DNS does not currently resolve it to ${API_ADDRESS}. Continuing with the authoritative API result." "Контроллер ${CONTROLLER_FQDN} определён MultiDirectory, но локальный DNS пока не разрешает его в ${API_ADDRESS}. Продолжение с авторитетным результатом API.")"
      log "Controller DNS verification did not confirm ${CONTROLLER_FQDN} -> ${API_ADDRESS}"
    fi
  fi

  REALM="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"
  KDC="$CONTROLLER_FQDN"
  KADMIN="$CONTROLLER_FQDN"
  # MultiDirectory provisions the LDAP service principal for the domain-level
  # LDAP endpoint (ldap/DOMAIN@REALM), while KDC/API routing remains tied to the
  # discovered controller.  Do not derive the LDAP SPN from CONTROLLER_FQDN.
  LDAP_GSSAPI_HOST="$DOMAIN"
  LDAP_SERVICE_PRINCIPAL="ldap/${LDAP_GSSAPI_HOST}@${REALM}"
  URI="ldap://${LDAP_GSSAPI_HOST}"
  LDAP_SEARCH_BASE="$LDAP_BASE_DN"
  LDAP_USER_BASE="$LDAP_BASE_DN"
  LDAP_GROUP_BASE="$LDAP_BASE_DN"
  LDAP_COMPUTER_OU="cn=computers,${LDAP_BASE_DN}"

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    build_salt_master_fqdns
  fi

  log "Continuing common Join flow"
  return 0
}

normalize_controller_fqdn() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value%.}"
  printf '%s' "$value"
}

controller_fqdn_in_domain() {
  local candidate="$1"

  valid_join_domain "$candidate" || return 1
  [[ "$candidate" == "$DOMAIN" || "$candidate" == *."$DOMAIN" ]]
}

controller_fqdn_resolves_to_address() {
  local candidate="$1"
  local address="$2"

  getent ahostsv4 "$candidate" 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "$address"
}

controller_fqdn_from_ptr() {
  local address="$1"
  local candidate

  candidate="$(getent hosts "$address" 2>/dev/null | awk 'NR == 1 {print $2}')"
  candidate="$(normalize_controller_fqdn "$candidate")"
  controller_fqdn_in_domain "$candidate" || return 1
  printf '%s' "$candidate"
}

discover_controller_fqdn() {
  local rootdse_dns_host="${1:-}"
  local candidate="" source=""

  if ! valid_ipv4_address "$API_ADDRESS"; then
    CONTROLLER_FQDN="$(normalize_controller_fqdn "$API_ADDRESS")"
    controller_fqdn_in_domain "$CONTROLLER_FQDN" \
      || die "API server FQDN does not belong to detected domain ${DOMAIN}: ${CONTROLLER_FQDN}"
    log "Controller FQDN supplied directly: ${CONTROLLER_FQDN}"
    return 0
  fi

  candidate="$(api_controller_fqdn_from_dns "$access_token" "$API_ADDRESS" "$DOMAIN" 2>/dev/null || true)"
  candidate="$(normalize_controller_fqdn "$candidate")"
  if controller_fqdn_in_domain "$candidate"; then
    source="MultiDirectory DNS API"
  else
    candidate=""
  fi

  if [[ -z "$candidate" && -n "$rootdse_dns_host" ]]; then
    candidate="$(normalize_controller_fqdn "$rootdse_dns_host")"
    if controller_fqdn_in_domain "$candidate" \
        && controller_fqdn_resolves_to_address "$candidate" "$API_ADDRESS"; then
      source="RootDSE dnsHostName"
    else
      candidate=""
    fi
  fi

  if [[ -z "$candidate" ]]; then
    candidate="$(controller_fqdn_from_ptr "$API_ADDRESS" 2>/dev/null || true)"
    [[ -z "$candidate" ]] || source="PTR lookup"
  fi

  if [[ -z "$candidate" && -n "${SAVED_CONTROLLER_FQDN:-}" ]]; then
    candidate="$(normalize_controller_fqdn "$SAVED_CONTROLLER_FQDN")"
    if controller_fqdn_in_domain "$candidate" \
        && controller_fqdn_resolves_to_address "$candidate" "$API_ADDRESS"; then
      source="saved join state"
    else
      candidate=""
    fi
  fi

  [[ -n "$candidate" ]] || die "$(ui_text "Cannot determine a controller FQDN for ${API_ADDRESS}. The DNS API, RootDSE and PTR lookup returned no usable name." "Не удалось определить FQDN контроллера для ${API_ADDRESS}. DNS API, RootDSE и PTR не вернули подходящее имя.")"

  CONTROLLER_FQDN="$candidate"
  log "Controller discovery source: ${source}; ${API_ADDRESS} -> ${CONTROLLER_FQDN}"
  return 0
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
    sssctl config-check >> "$LOG_FILE" 2>&1 || die "SSSD configuration validation failed"
    ok "SSSD configuration validated"
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

  if [[ ! -f "$MD_SSSD_SOCKET_STATE" ]]; then
    : > "$MD_SSSD_SOCKET_STATE"
    chmod 600 "$MD_SSSD_SOCKET_STATE"
  fi

  for unit in "${sockets[@]}"; do
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^${unit}"; then
      if ! grep -Fq "${unit}|" "$MD_SSSD_SOCKET_STATE" 2>/dev/null; then
        printf '%s|%s|%s\n' \
          "$unit" \
          "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
          "$(systemctl is-active "$unit" 2>/dev/null || true)" \
          >> "$MD_SSSD_SOCKET_STATE"
      fi
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

restore_sssd_socket_state() {
  local unit enabled_state active_state remask

  [[ -f "$MD_SSSD_SOCKET_STATE" ]] || return 0
  have_cmd systemctl || {
    warn "Cannot restore SSSD socket state: systemctl is unavailable"
    return 1
  }

  while IFS='|' read -r unit enabled_state active_state; do
    [[ -n "$unit" ]] || continue

    remask=0
    systemctl unmask "$unit" >/dev/null 2>&1 || true
    case "$enabled_state" in
      enabled|enabled-runtime|linked|linked-runtime|alias)
        systemctl enable "$unit" >/dev/null 2>&1 || true
        ;;
      masked|masked-runtime)
        remask=1
        ;;
      disabled)
        systemctl disable "$unit" >/dev/null 2>&1 || true
        ;;
      static|indirect|generated|transient)
        ;;
      *)
        warn "Unknown saved enable state for ${unit}: ${enabled_state}"
        ;;
    esac

    if [[ "$active_state" == "active" ]]; then
      systemctl start "$unit" >/dev/null 2>&1 || true
    else
      systemctl stop "$unit" >/dev/null 2>&1 || true
    fi

    if [[ "$remask" -eq 1 ]]; then
      systemctl mask "$unit" >/dev/null 2>&1 || true
    fi
  done < "$MD_SSSD_SOCKET_STATE"

  rm -f "$MD_SSSD_SOCKET_STATE"
  log "Restored SSSD socket activation state"
}
