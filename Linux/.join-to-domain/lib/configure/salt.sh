api_delete_salt_minion_key() {
  local cookie="$1"
  local minion_id="$2"

  [[ -n "$minion_id" ]] || return 0

  curl -k -sS -X DELETE "https://${API_HOST}/api/salt/minion/${minion_id}" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "Cookie: id=${cookie}" \
    -H 'accept: application/json' \
    -o /dev/null || true
}

install_salt_custom_modules() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || return 0

  if [[ ! -f "$SALT_PKG_MODULE_SRC" ]]; then
    warn "Custom Salt pkg module not found, skipping: ${SALT_PKG_MODULE_SRC}"
    return 0
  fi

  require_salt_minion_ready

  log "Installing custom Salt module: ${SALT_PKG_MODULE_DST}"

  mkdir -p "$SALT_MINION_EXTMODS_MODULES_DIR"
  md_backup_once "$SALT_PKG_MODULE_DST"

  install -m 0644 -o root -g root "$SALT_PKG_MODULE_SRC" "$SALT_PKG_MODULE_DST"
  md_track "$SALT_PKG_MODULE_DST"

  if have_cmd salt-call; then
    salt-call --local saltutil.refresh_modules >/dev/null 2>&1 \
      && log "Salt custom modules refreshed" \
      || warn "saltutil.refresh_modules failed; module will be loaded after salt-minion restart"
  else
    warn "salt-call not found, Salt custom modules refresh skipped"
  fi

  log "Custom Salt pkg module installed"
}

prepare_salt_minion_identity() {
  local guid="$1"
  local gpo_token="$2"

  require_salt_minion_ready

  log "Preparing Salt minion identity: ${guid}"

  if pgrep -f "salt-minion" > /dev/null 2>&1; then
    pkill -9 -f "salt-minion" 2>/dev/null || true
    sleep 2
    # Проверяем, что убили
    if pgrep -f "salt-minion" > /dev/null 2>&1; then
      warn "Some salt-minion processes still remain, killing again..."
      pkill -9 -f "salt-minion" 2>/dev/null || true
      sleep 1
    fi
    log "Salt processes stopped"
  fi

  rm -rf /etc/salt/pki/minion 2>/dev/null || true
  rm -f /etc/salt/minion_id 2>/dev/null || true

  mkdir -p /etc/salt

  cat > /etc/salt/minion <<EOF
master: ${SALT_MASTER}
master_finger: ${gpo_token}
EOF

  md_backup_once /etc/salt/minion
  md_track /etc/salt/minion

  if [[ -d /etc/salt/minion.d ]]; then
    find /etc/salt/minion.d -type f -name '*.conf' -exec sed -i '/^\s*master\s*:/d' {} \; 2>/dev/null || true
    find /etc/salt/minion.d -type f -name '*.conf' -exec sed -i '/^\s*master_finger\s*:/d' {} \; 2>/dev/null || true
    find /etc/salt/minion.d -type f -name '*.conf' -exec sed -i '/^\s*id\s*:/d' {} \; 2>/dev/null || true
  fi

  echo "$guid" > /etc/salt/minion_id
  chmod 0644 /etc/salt/minion_id
  md_track /etc/salt/minion_id

  systemctl daemon-reload || true
  systemctl enable salt-minion.service >/dev/null 2>&1 || true

  log "Salt minion identity prepared"
}

restart_salt_minion_and_wait() {
  local wait_seconds="${1:-8}"

  restart_salt_minion_or_die

  log "Waiting ${wait_seconds}s for Salt minion key publication"
  sleep "$wait_seconds"
}

accept_salt_minion_key() {
  local guid="$1"
  local resp http_code body
  local retries=12
  local delay=5
  local attempt=1

  while [[ $attempt -le $retries ]]; do
    log "Attempt ${attempt}/${retries}: accepting Salt minion key"

    resp="$(
      curl -k -sS -w "\n%{http_code}" \
        --connect-timeout "${API_CONNECT_TIMEOUT}" \
        --max-time "${API_MAX_TIME}" \
        -X POST "https://${API_HOST}/api/salt/minion" \
        -H 'accept: application/json' \
        -H "Cookie: id=${access_token}" \
        -H 'Content-Type: application/json' \
        -d "{\"id\": \"${guid}\"}" 2>&1
    )" || true

    http_code="$(echo "$resp" | tail -n1)"
    body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" -eq 200 ]]; then
      log "Salt minion key accepted"
      restart_salt_minion_or_die
      return 0
    fi

    if [[ "$http_code" -eq 400 ]] && echo "$body" | grep -qi "Minion Already Exists"; then
      warn "Minion already exists on master. Deleting old key and publishing a fresh key."

      systemctl stop salt-minion.service 2>/dev/null || true
      rm -rf /etc/salt/pki/minion 2>/dev/null || true
      api_delete_salt_minion_key "${access_token}" "${guid}"

      restart_salt_minion_and_wait 8
      ((attempt++))
      continue
    fi

    if [[ "$http_code" -eq 400 ]] && echo "$body" | grep -qi "Unable to accept minion"; then
      warn "Salt key is not ready on master yet. Waiting before retry."
      sleep "$delay"

      if (( attempt % 3 == 0 )); then
        warn "Restarting salt-minion to force key publication"
        restart_salt_minion_and_wait 8
      fi

      ((attempt++))
      continue
    fi

    warn "Salt API returned HTTP ${http_code}: ${body}"
    sleep "$delay"
    ((attempt++))
  done

  print_salt_diagnostics
  die "Failed to accept Salt minion key"
}

configure_salt() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || {
    log "Community edition: Salt steps skipped"
    return 0
  }

  local gpo_token guid

  SALT_MASTER="salt.${DOMAIN}"

  require_salt_minion_ready

  log "Checking DNS resolution: SALT_MASTER=${SALT_MASTER}"
  getent hosts "${SALT_MASTER}" >/dev/null || die "DNS resolution failed for ${SALT_MASTER}"

  gpo_token="$(
    curl -k -sS -X GET "https://${API_HOST}/api/salt/master/key" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -H "Cookie: id=${access_token}" \
      -H 'accept: application/json' \
      | tr -d '\r\n"'
  )"

  [[ -n "${gpo_token}" ]] || die "Failed to get Salt master_finger"

  log "Getting computer objectGUID"
  guid="$(
    api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=*)(cn=${HOSTNAME}))" "[\"objectGUID\"]" \
      | jq -r '.search_result[0].partial_attributes[]? | select(.type=="objectGUID") | .vals[0] // empty'
  )"

  [[ -n "${guid}" ]] || die "Failed to get objectGUID"

  prepare_salt_minion_identity "$guid" "$gpo_token"

  warn "Deleting possible old Salt key for this minion id before fresh registration"
  api_delete_salt_minion_key "${access_token}" "${guid}"

  restart_salt_minion_and_wait 8
  accept_salt_minion_key "$guid"
}

save_join_env() {
  cat > "${MD_JOIN_ENV}" <<EOF
API_HOST=${API_HOST}
DOMAIN=${DOMAIN}
REALM=${REALM}
HOSTNAME=${HOSTNAME}
FQDN=${FQDN}
LDAP_BASE_DN=${LDAP_BASE_DN}
LDAP_COMPUTER_OU=${LDAP_COMPUTER_OU}
EDITION=${EDITION}
WITH_SALT=${WITH_SALT}
SALT_MASTER=${SALT_MASTER:-}
MD_DNS_SERVER=${MD_DNS_SERVER:-}
EOF

  chmod 600 "${MD_JOIN_ENV}"
  md_track "${MD_JOIN_ENV}"
}

