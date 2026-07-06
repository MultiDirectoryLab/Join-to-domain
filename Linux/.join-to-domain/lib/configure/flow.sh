join_domain() {
  preflight
  md_init_state
  load_join_state

  trap on_join_error ERR

  load_or_prompt_edition
  validate_files_structure
  prompt_configure_dns

  if env_has_key API_HOST; then
    [[ -n "${API_HOST:-}" ]] || die "API_HOST is empty in environment"
    if getent hosts "${API_HOST}" >/dev/null; then
      log "DNS resolution OK: ${API_HOST}"
    else
      die "DNS resolution failed for API_HOST from environment: ${API_HOST}"
    fi
  else
    while true; do
      if [[ -n "${SAVED_API_HOST:-}" ]]; then
        read_tty API_HOST "Enter MULTIDIRECTORY server address (FQDN) [${SAVED_API_HOST}]:"
        API_HOST="${API_HOST:-$SAVED_API_HOST}"
      else
        read_tty API_HOST "Enter MULTIDIRECTORY server address (FQDN), for example webadmin.domain.ru:"
      fi
      if [[ -z "${API_HOST}" ]]; then
        warn "API host must be filled."
        continue
      fi
      if ! valid_join_domain "${API_HOST}"; then
        warn "Invalid API host. Enter a FQDN, for example webadmin.domain.ru."
        continue
      fi
      if getent hosts "${API_HOST}" >/dev/null; then
        log "DNS resolution OK: ${API_HOST}"
        break
      else
        warn "DNS resolution failed for ${API_HOST}. Please check the address."
      fi
    done
  fi

  while true; do
    read_tty LOGIN "Enter administrator login, for example admin:"
    read_secret_tty PASSWORD "Enter administrator password:"
    if [[ -z "${LOGIN}" || -z "${PASSWORD}" ]]; then
      warn "Login and password must be filled."
      continue
    fi
    log "Authenticating domain administrator via API"
    if access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")" && [[ -n "${access_token}" ]]; then
      log "Domain administrator credentials are valid"
      break
    else
      warn "Authentication failed. Please check login and password."
    fi
  done
  discover_and_validate_domain

  prompt_change_hostname

  log "DOMAIN=${DOMAIN}"
  log "REALM=${REALM}"
  log "LDAP_BASE_DN=${LDAP_BASE_DN}"
  log "HOSTNAME=${HOSTNAME}"
  log "FQDN=${FQDN}"
  log "EDITION=${EDITION}"
  log "WITH_SALT=${WITH_SALT}"

  install_static_configs
  validate_no_password_based_sssd_auth
  validate_sssd_config

  create_computer_object_if_needed

  log "Getting keytab"
  api_ktadd_download "${access_token}" "host/${HOSTNAME}" "host/${FQDN}"

  validate_keytab
  validate_ldap_gssapi_auth
  configure_astra_se_parsec_sssd

  configure_salt

  unset PASSWORD

  save_join_env
  start_services

  trap - ERR

  log "Configuration completed successfully"
  warn "System reboot is recommended"
}

require_install_packages_launcher() {
  if [[ "${MD_CALLED_FROM_INSTALL_PACKAGES:-0}" != "1" ]]; then
    if [[ -w /dev/tty ]]; then
      echo "[ERR] Use the public launcher: sudo ${PUBLIC_LAUNCHER}" > /dev/tty
    else
      echo "[ERR] Use the public launcher: sudo ${PUBLIC_LAUNCHER}" >&2
    fi
    exit 126
  fi
}

main() {
  require_install_packages_launcher "${1:-join}"

  case "${1:-}" in
    join)
      join_domain
      ;;
    leave)
      leave_domain
      ;;
    *)
      usage
      ;;
  esac
}
