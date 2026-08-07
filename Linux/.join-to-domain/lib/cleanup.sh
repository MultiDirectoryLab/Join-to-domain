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
    "$MD_GPUPDATE_LINK"
    "$MD_GPUPDATE_DST"
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

cleanup_read_tty() {
  local var="$1"
  local prompt="$2"

  printf '%s ' "$prompt"
  read_clean_input "$var" || {
    warn "Input contains invalid characters. Please enter the value again."
  }
}

cleanup_read_secret_tty() {
  local var="$1"
  local prompt="$2"

  printf -v "$var" '%s' ""
  printf '%s ' "$prompt"
  IFS= read -rs "${var?}"
  printf '\n'
}

cleanup_join_state_value() {
  local key="$1"
  local line value

  [[ -f "$MD_JOIN_ENV" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="$(sanitize_input "$line")"

    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue

    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="$(sanitize_input "$line")"
    fi

    [[ "$line" == *=* ]] || continue
    [[ "${line%%=*}" == "$key" ]] || continue

    value="${line#*=}"
    value="$(sanitize_input "$value")"

    if [[ "$value" == \"*\" && "$value" == *\" && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
      value="${value//\\\"/\"}"
      value="${value//\\\\/\\}"
    elif [[ "$value" == \'*\' && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    validate_utf8_input "$value" || return 1
    printf '%s\n' "$value"
    return 0
  done < "$MD_JOIN_ENV"

  return 1
}

cleanup_valid_domain_name() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

cleanup_valid_ipv4_address() {
  local ip="$1"
  local IFS=.
  local octets octet

  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

cleanup_valid_api_host() {
  cleanup_valid_ipv4_address "$1" || cleanup_valid_domain_name "$1"
}

cleanup_api_host_resolution_ok() {
  if cleanup_valid_ipv4_address "$1"; then
    return 0
  fi

  getent hosts "$1" >/dev/null
}

cleanup_api_auth_cookie() {
  local api_host="$1"
  local user="$2"
  local pass="$3"

  curl -k -sS -X POST "https://${api_host}/api/auth/" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}" \
    -D - -o /dev/null \
    | awk -F'id=|;' 'BEGIN{IGNORECASE=1} /set-cookie:[[:space:]]*id=/{print $2; exit}' \
    | tr -d '\r\n'
}

cleanup_api_search() {
  local api_host="$1"
  local cookie="$2"
  local base_object="$3"
  local scope="$4"
  local filter="$5"
  local attrs_json="$6"
  local size_limit="${7:-5}"

  curl -k -sS -X POST "https://${api_host}/api/entry/search" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Cookie: id=${cookie}" \
    -H "Content-Type: application/json" \
    -d "{
      \"base_object\": \"${base_object}\",
      \"scope\": ${scope},
      \"deref_aliases\": 0,
      \"size_limit\": ${size_limit},
      \"time_limit\": 0,
      \"types_only\": false,
      \"filter\": \"${filter}\",
      \"attributes\": ${attrs_json}
    }"
}

cleanup_api_response_attribute() {
  local attribute="$1"

  jq -r --arg wanted "$attribute" '
    [
      .. | objects |
      if (((.type? // .name? // "") | tostring | ascii_downcase) == ($wanted | ascii_downcase)) then
        (.vals? // .values? // empty) |
        if type == "array" then .[0] else . end
      else
        to_entries[]? |
        select((.key | ascii_downcase) == ($wanted | ascii_downcase)) |
        .value |
        if type == "array" then .[0] else . end
      end
    ]
    | map(select(. != null and . != ""))
    | .[0] // empty
  '
}

cleanup_dn_to_domain() {
  awk -F',' '
    {
      out="";
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i);
        if ($i ~ /^dc=/ || $i ~ /^DC=/) {
          sub(/^[dD][cC]=/, "", $i);
          out = (out == "" ? $i : out "." $i);
        }
      }
      print tolower(out);
    }
  '
}

cleanup_api_rootdse_domain() {
  local api_host="$1"
  local cookie="$2"
  local resp dom nc

  resp="$(
    cleanup_api_search "$api_host" "$cookie" "" 0 "(objectClass=*)" \
      '["dnsHostName","rootDomainNamingContext","defaultNamingContext","namingContexts","subschemaSubentry","supportedLDAPVersion","supportedSASLMechanisms","supportedExtension","supportedControl","supportedFeatures","vendorName","name","vendorVersion","objectClass"]' \
      0
  )"

  dom="$(printf '%s' "$resp" | cleanup_api_response_attribute "dnsHostName")"
  [[ -n "$dom" ]] || dom="$(printf '%s' "$resp" | cleanup_api_response_attribute "dnsDomainName")"
  [[ -n "$dom" ]] || dom="$(printf '%s' "$resp" | cleanup_api_response_attribute "dnsForestName")"

  if [[ -z "$dom" ]]; then
    nc="$(printf '%s' "$resp" | cleanup_api_response_attribute "defaultNamingContext")"
    [[ -n "$nc" ]] || nc="$(printf '%s' "$resp" | cleanup_api_response_attribute "rootDomainNamingContext")"
    [[ -n "$nc" ]] || nc="$(printf '%s' "$resp" | cleanup_api_response_attribute "namingContexts")"
    [[ -n "$nc" ]] && dom="$(printf '%s' "$nc" | cleanup_dn_to_domain)"
  fi

  printf '%s' "$dom"
}

cleanup_validate_remote_credentials() {
  local saved_domain saved_api_host login password token detected_domain

  CLEANUP_REMOTE_READY=0

  [[ -f "$MD_JOIN_ENV" ]] || warn "Join state file not found: ${MD_JOIN_ENV}; asking for remote cleanup details"

  saved_domain="$(cleanup_join_state_value DOMAIN 2>/dev/null || true)"
  saved_api_host="$(cleanup_join_state_value API_HOST 2>/dev/null || true)"
  LDAP_COMPUTER_OU="$(cleanup_join_state_value LDAP_COMPUTER_OU 2>/dev/null || true)"
  HOSTNAME="$(cleanup_join_state_value HOSTNAME 2>/dev/null || true)"
  SALT_MINION_ID="$(cleanup_join_state_value SALT_MINION_ID 2>/dev/null || true)"
  WITH_SALT="$(cleanup_join_state_value WITH_SALT 2>/dev/null || true)"

  [[ -n "$saved_domain" ]] || warn "DOMAIN is missing in ${MD_JOIN_ENV}; it will be detected after authentication"

  while [[ -z "$saved_api_host" ]]; do
    cleanup_read_tty saved_api_host "Enter MULTIDIRECTORY server address (IPv4 or FQDN):"
    if [[ -z "$saved_api_host" ]]; then
      warn "API host must be filled."
      continue
    fi
    if ! cleanup_valid_api_host "$saved_api_host"; then
      warn "Invalid API host. Enter an IPv4 address or FQDN."
      saved_api_host=""
    fi
  done

  cleanup_read_tty login "Enter domain administrator login:"
  cleanup_read_secret_tty password "Enter domain administrator password:"

  [[ -n "$login" && -n "$password" ]] || {
    unset password
    error "Login and password must be filled"
    return 1
  }

  info "Checking API host address: ${saved_api_host}"
  cleanup_api_host_resolution_ok "${saved_api_host}" || {
    unset password
    error "DNS resolution failed: ${saved_api_host}"
    return 1
  }

  info "Authenticating domain administrator"
  token="$(cleanup_api_auth_cookie "$saved_api_host" "$login" "$password")"
  unset password

  [[ -n "$token" ]] || {
    error "Failed to authenticate domain administrator"
    return 1
  }

  saved_domain="$(printf '%s' "$saved_domain" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "$saved_domain" ]]; then
    detected_domain="$saved_domain"
    info "Using domain from saved join state: ${saved_domain}"
  else
    info "Detecting domain via RootDSE"
    detected_domain="$(cleanup_api_rootdse_domain "$saved_api_host" "$token" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$detected_domain" ]] || {
      error "Failed to detect domain via RootDSE and no saved domain is available"
      return 1
    }
    saved_domain="$detected_domain"
  fi

  API_HOST="$saved_api_host"
  access_token="$token"
  CLEANUP_REMOTE_READY=1

  info "Leave credentials validated"
}

cleanup_delete_salt_minion_key() {
  local minion_id="$1"
  local resp http_code body

  [[ -n "$minion_id" ]] || return 0

  resp="$(
    curl -k -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X DELETE "https://${API_HOST}/api/salt/minion/${minion_id}" \
      -H "Cookie: id=${access_token}" \
      -H 'accept: application/json' 2>&1
  )" || {
    warn "Failed to request Salt key deletion for ${minion_id}; continuing"
    cleanup_log "Salt key deletion request failed: ${minion_id}"
    return 0
  }

  http_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ || "$http_code" == "404" ]]; then
    info "Salt key deleted or was not present: ${minion_id}"
    cleanup_log "Salt key deleted or absent: ${minion_id}"
    return 0
  fi

  warn "Salt key deletion returned HTTP ${http_code}: ${body}"
  cleanup_log "Salt key deletion returned HTTP ${http_code}: ${body}"
  return 0
}

cleanup_delete_salt_key_on_leave() {
  local minion_id lookup_resp

  [[ "${WITH_SALT:-0}" -eq 1 ]] || {
    cleanup_log "Salt key cleanup skipped: Community edition or WITH_SALT is not enabled"
    return 0
  }

  minion_id="${SALT_MINION_ID:-}"

  if [[ -z "$minion_id" && -f /etc/salt/minion_id ]]; then
    minion_id="$(tr -d '\r\n' < /etc/salt/minion_id 2>/dev/null || true)"
  fi

  if [[ -z "$minion_id" && -n "${LDAP_COMPUTER_OU:-}" && -n "${HOSTNAME:-}" ]]; then
    info "Getting Salt minion id from computer objectGUID"
    lookup_resp="$(
      cleanup_api_search "$API_HOST" "$access_token" "$LDAP_COMPUTER_OU" 2 "(&(objectClass=*)(cn=${HOSTNAME}))" "[\"objectGUID\"]"
    )" || {
      warn "Failed to get computer objectGUID, Salt key cleanup skipped"
      return 0
    }

    minion_id="$(printf '%s' "$lookup_resp" | cleanup_api_response_attribute "objectGUID" 2>/dev/null || true)"
  fi

  if [[ -z "$minion_id" ]]; then
    warn "Salt minion id is unknown, Salt key cleanup skipped"
    cleanup_log "Salt key cleanup skipped: minion id unknown"
    return 0
  fi

  warn "Deleting Salt key on master for minion id: ${minion_id}"
  cleanup_delete_salt_minion_key "$minion_id"
}

cleanup_disable_computer_account() {
  local expected_dn lookup_resp object_dn payload resp http_code body

  [[ -n "${LDAP_COMPUTER_OU:-}" && -n "${HOSTNAME:-}" ]] || {
    warn "Computer LDAP path is unknown, computer account disable skipped"
    cleanup_log "Computer account disable skipped: missing LDAP_COMPUTER_OU or HOSTNAME"
    return 0
  }

  expected_dn="cn=${HOSTNAME},${LDAP_COMPUTER_OU}"

  lookup_resp="$(
    cleanup_api_search "$API_HOST" "$access_token" "$LDAP_COMPUTER_OU" 2 "(&(objectClass=computer)(cn=${HOSTNAME}))" "[\"cn\",\"userAccountControl\"]"
  )" || {
    warn "Failed to check computer object, skipping remote disable: ${expected_dn}"
    cleanup_log "Computer account lookup failed: ${expected_dn}"
    return 0
  }

  object_dn="$(printf '%s' "$lookup_resp" | jq -r '.search_result[0].object_name // empty' 2>/dev/null || true)"

  if [[ -z "$object_dn" ]]; then
    warn "Computer object not found in LDAP: ${expected_dn}"
    warn "Skipping remote computer disable"
    cleanup_log "Computer object not found: ${expected_dn}"
    return 0
  fi

  warn "Disabling computer account: ${object_dn}"
  payload="$(jq -n \
    --arg object "$object_dn" \
    '[
      {
        object: $object,
        changes: [
          {
            operation: 2,
            modification: {
              type: "userAccountControl",
              vals: ["4098"]
            }
          }
        ]
      }
    ]'
  )"

  resp="$(
    curl -k -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X PATCH "https://${API_HOST}/api/entry/update_many" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Cookie: id=${access_token}" \
      -d "${payload}" 2>&1
  )" || true

  http_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    info "Computer account disabled: ${object_dn}"
    cleanup_log "Computer account disabled: ${object_dn}"
    return 0
  fi

  warn "Computer account was not disabled on server side. HTTP ${http_code}: ${body}"
  cleanup_log "Computer account disable failed. HTTP ${http_code}: ${body}"
  return 0
}

cleanup_remote_domain_objects() {
  local cmd

  for cmd in curl jq getent awk tr; do
    if ! have_cmd "$cmd"; then
      error "Command not found: ${cmd}"
      return 1
    fi
  done

  info "Starting remote cleanup for safe leave"
  cleanup_validate_remote_credentials || return 1
  [[ "${CLEANUP_REMOTE_READY:-0}" -eq 1 ]] || {
    warn "Remote cleanup skipped"
    return 0
  }
  cleanup_delete_salt_key_on_leave
  cleanup_disable_computer_account
  info "Remote cleanup step completed"
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
  cleanup_remote_domain_objects || return 1

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
