JOIN_STATE_LOADED=0

join_state_value() {
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

valid_join_domain() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_join_realm() {
  local value="$1"

  [[ "$value" =~ ^[A-Z0-9]([A-Z0-9.-]{0,251}[A-Z0-9])?$ ]]
}

valid_join_ldap_dn() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z][A-Za-z0-9-]*=.+(,[A-Za-z][A-Za-z0-9-]*=.+)*$ ]]
}

valid_join_fqdn() {
  local fqdn="$1"
  local hostname="$2"
  local domain="$3"

  [[ -n "$fqdn" && -n "$hostname" && -n "$domain" ]] || return 1
  [[ "$fqdn" == "${hostname}.${domain}" ]]
}

load_join_state_field() {
  local key="$1"
  local target="$2"
  local validator="${3:-}"
  local value

  if ! value="$(join_state_value "$key")"; then
    return 1
  fi

  if [[ -n "$validator" ]] && ! "$validator" "$value"; then
    warn "Ignoring invalid ${key} in ${MD_JOIN_ENV}"
    return 1
  fi

  printf -v "$target" '%s' "$value"
  JOIN_STATE_LOADED=1
  return 0
}

load_join_state_dns() {
  local value normalized

  if value="$(join_state_value DNS_SERVERS)" || value="$(join_state_value MD_DNS_SERVER)"; then
    if normalized="$(normalize_dns_servers "$value")"; then
      SAVED_DNS_SERVERS="$normalized"
      JOIN_STATE_LOADED=1
      return 0
    fi

    warn "Ignoring invalid DNS_SERVERS in ${MD_JOIN_ENV}"
  fi

  return 1
}

load_join_state_edition() {
  local edition with_salt

  edition="$(join_state_value EDITION 2>/dev/null || true)"
  with_salt="$(join_state_value WITH_SALT 2>/dev/null || true)"

  if [[ "$edition" == "enterprise" && "$with_salt" == "1" ]]; then
    SAVED_EDITION="enterprise"
    SAVED_WITH_SALT=1
    JOIN_STATE_LOADED=1
    return 0
  fi

  if [[ "$edition" == "community" && "$with_salt" == "0" ]]; then
    SAVED_EDITION="community"
    SAVED_WITH_SALT=0
    JOIN_STATE_LOADED=1
    return 0
  fi

  if [[ -n "$edition" || -n "$with_salt" ]]; then
    warn "Ignoring invalid EDITION/WITH_SALT in ${MD_JOIN_ENV}"
  fi

  return 1
}

load_join_state() {
  SAVED_DOMAIN=""
  SAVED_REALM=""
  SAVED_LDAP_BASE_DN=""
  SAVED_LDAP_COMPUTER_OU=""
  SAVED_HOSTNAME=""
  SAVED_FQDN=""
  SAVED_API_HOST=""
  SAVED_DNS_SERVERS=""
  SAVED_EDITION=""
  SAVED_WITH_SALT=""
  SAVED_SALT_MASTER=""
  SAVED_SALT_MINION_ID=""
  SAVED_COMPUTER_DN=""
  JOIN_STATE_LOADED=0

  [[ -f "$MD_JOIN_ENV" ]] || {
    log "Join state file not found: ${MD_JOIN_ENV}"
    return 0
  }

  load_join_state_field DOMAIN SAVED_DOMAIN valid_join_domain || true
  load_join_state_field REALM SAVED_REALM valid_join_realm || true
  load_join_state_field LDAP_BASE_DN SAVED_LDAP_BASE_DN valid_join_ldap_dn || true
  load_join_state_field LDAP_COMPUTER_OU SAVED_LDAP_COMPUTER_OU valid_join_ldap_dn || true
  load_join_state_field API_HOST SAVED_API_HOST valid_join_domain || true
  load_join_state_field HOSTNAME SAVED_HOSTNAME valid_hostname || true
  load_join_state_field SALT_MASTER SAVED_SALT_MASTER valid_join_domain || true
  load_join_state_field SALT_MINION_ID SAVED_SALT_MINION_ID || true
  load_join_state_field COMPUTER_DN SAVED_COMPUTER_DN valid_join_ldap_dn || true
  load_join_state_dns || true
  load_join_state_edition || true

  if load_join_state_field FQDN SAVED_FQDN valid_join_domain; then
    if [[ -n "$SAVED_HOSTNAME" && -n "$SAVED_DOMAIN" ]] && ! valid_join_fqdn "$SAVED_FQDN" "$SAVED_HOSTNAME" "$SAVED_DOMAIN"; then
      warn "Ignoring invalid FQDN in ${MD_JOIN_ENV}: it does not match HOSTNAME.DOMAIN"
      SAVED_FQDN=""
    fi
  fi

  if [[ "$JOIN_STATE_LOADED" -eq 1 ]]; then
    log "Loaded join state defaults from ${MD_JOIN_ENV}"
  else
    warn "No valid join state values found in ${MD_JOIN_ENV}"
  fi
}

shell_quote_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

write_join_state_var() {
  local key="$1"
  local value="$2"

  printf '%s=' "$key"
  shell_quote_value "$value"
  printf '\n'
}

save_join_env() {
  local tmp computer_dn joined_at dns_servers

  mkdir -p "$MD_STATE_DIR"
  chmod 700 "$MD_STATE_DIR"

  tmp="$(mktemp "${MD_STATE_DIR}/join.env.tmp.XXXXXX")"
  joined_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
  computer_dn="${COMPUTER_DN:-cn=${HOSTNAME},${LDAP_COMPUTER_OU}}"
  dns_servers="${MD_DNS_SERVER:-}"

  {
    write_join_state_var DOMAIN "${DOMAIN}"
    write_join_state_var REALM "${REALM}"
    write_join_state_var LDAP_BASE_DN "${LDAP_BASE_DN}"
    write_join_state_var HOSTNAME "${HOSTNAME}"
    write_join_state_var FQDN "${FQDN}"
    write_join_state_var API_HOST "${API_HOST}"
    write_join_state_var DNS_SERVERS "${dns_servers}"
    write_join_state_var EDITION "${EDITION}"
    write_join_state_var WITH_SALT "${WITH_SALT}"
    write_join_state_var LDAP_COMPUTER_OU "${LDAP_COMPUTER_OU}"
    write_join_state_var COMPUTER_DN "${computer_dn}"
    write_join_state_var SALT_MASTER "${SALT_MASTER:-}"
    write_join_state_var SALT_MINION_ID "${SALT_MINION_ID:-}"
    write_join_state_var JOINED_AT "${joined_at}"
  } > "$tmp"

  chmod 600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$MD_JOIN_ENV"
  chmod 600 "$MD_JOIN_ENV"
  chown root:root "$MD_JOIN_ENV" 2>/dev/null || true
  md_track "$MD_JOIN_ENV"

  log "Join state saved: ${MD_JOIN_ENV}"
}
