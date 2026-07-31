api_delete_salt_minion_key() {
  local cookie="$1"
  local minion_id="$2"
  local resp http_code body

  [[ -n "$minion_id" ]] || return 0

  resp="$(
    curl -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X DELETE "https://${API_HOST}/api/salt/minion/${minion_id}" \
      -H "Cookie: id=${cookie}" \
      -H 'accept: application/json' 2>&1
  )" || {
    warn "Failed to request Salt key deletion for ${minion_id}; continuing"
    return 0
  }

  http_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ || "$http_code" == "404" ]]; then
    log "Salt key deleted or was not present: ${minion_id}"
    return 0
  fi

  warn "Salt key deletion returned HTTP ${http_code}: ${body}"
  warn "Continuing without blocking the current operation"
  return 0
}

delete_salt_minion_key_on_leave() {
  local guid lookup_resp

  [[ "${WITH_SALT:-0}" -eq 1 ]] || {
    log "Community edition: Salt key cleanup skipped"
    return 0
  }

  [[ -n "${access_token:-}" ]] || {
    warn "API access token is missing, Salt key cleanup skipped"
    return 0
  }

  guid="${SALT_MINION_ID:-}"

  if [[ -z "$guid" ]]; then
    [[ -n "${LDAP_COMPUTER_OU:-}" && -n "${HOSTNAME:-}" ]] || {
      warn "Computer LDAP path is unknown, Salt key cleanup skipped"
      return 0
    }

    log "Getting Salt minion id from computer objectGUID"
    lookup_resp="$(
      api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=*)(cn=${HOSTNAME}))" "[\"objectGUID\"]"
    )" || {
      warn "Failed to get computer objectGUID, Salt key cleanup skipped"
      return 0
    }

    guid="$(
      printf '%s' "$lookup_resp" \
        | jq -r '.search_result[0].partial_attributes[]? | select(.type=="objectGUID") | .vals[0] // empty' 2>/dev/null || true
    )"
  fi

  if [[ -z "$guid" ]]; then
    warn "Computer objectGUID not found, Salt key cleanup skipped"
    return 0
  fi

  warn "Deleting Salt key on master for minion id: ${guid}"
  api_delete_salt_minion_key "${access_token}" "${guid}"
}

refresh_api_token_for_salt() {
  [[ -n "${LOGIN:-}" && -n "${PASSWORD:-}" ]] || return 0

  log "Refreshing API session before Salt key operations"
  access_token="$(api_auth_cookie "${LOGIN}" "${PASSWORD}")"
  [[ -n "${access_token}" ]] || die "Failed to refresh API session before Salt key operations"
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

install_md_gpupdate() {
  [[ "${WITH_SALT:-0}" -eq 1 ]] || return 0

  need_file "$MD_GPUPDATE_SRC"
  md_backup_once "$MD_GPUPDATE_DST"
  md_backup_once "$MD_GPUPDATE_LINK"

  mkdir -p "$(dirname "$MD_GPUPDATE_DST")" "$(dirname "$MD_GPUPDATE_LINK")"
  install -m 0755 -o root -g root "$MD_GPUPDATE_SRC" "$MD_GPUPDATE_DST"
  ln -sfn "$MD_GPUPDATE_DST" "$MD_GPUPDATE_LINK"

  md_track "$MD_GPUPDATE_DST"
  md_track "$MD_GPUPDATE_LINK"
  log "Installed md-gpupdate symlink: ${MD_GPUPDATE_LINK} -> ${MD_GPUPDATE_DST}"
}

configure_salt_pkg_provider() {
  local provider
  local provider_file="/etc/salt/minion.d/pkg_provider.conf"

  if is_deb_based; then
    provider="aptpkg"
  elif have_cmd dnf || have_cmd yum; then
    provider="yumpkg"
  elif have_cmd apt-get; then
    provider="aptpkg"
  else
    warn "Supported Salt pkg provider was not detected; skipping ${provider_file}"
    return 0
  fi

  mkdir -p "$(dirname -- "$provider_file")"
  md_backup_once "$provider_file"

  {
    printf 'providers:\n'
    printf '  pkg: %s\n' "$provider"
  } > "$provider_file"

  chmod 0644 "$provider_file"
  md_track "$provider_file"
  log "Configured Salt pkg provider: ${provider}"
}

prepare_salt_minion_identity() {
  local guid="$1"
  local gpo_token="$2"
  local existing_minion_id=""

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

  if [[ -f /etc/salt/minion_id ]]; then
    existing_minion_id="$(tr -d '\r\n' < /etc/salt/minion_id 2>/dev/null || true)"
    if [[ -n "$existing_minion_id" && "$existing_minion_id" != "$guid" ]]; then
      warn "Updating Salt minion id from ${existing_minion_id} to ${guid}; keeping the existing minion key pair"
      log "Deleting the previous Salt minion id before publishing the new one: ${existing_minion_id}"
      api_delete_salt_minion_key "${access_token}" "${existing_minion_id}"
    fi
  fi

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

  configure_salt_pkg_provider

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
  local resp http_code body curl_rc
  local retries=12
  local delay=5
  local attempt=1

  while [[ $attempt -le $retries ]]; do
    log "Attempt ${attempt}/${retries}: accepting Salt minion key"

    if resp="$(
      curl -sS -w "\n%{http_code}" \
        --connect-timeout "${API_CONNECT_TIMEOUT}" \
        --max-time "${API_MAX_TIME}" \
        -X POST "https://${API_HOST}/api/salt/minion" \
        -H 'accept: application/json' \
        -H "Cookie: id=${access_token}" \
        -H 'Content-Type: application/json' \
        -d "{\"id\": \"${guid}\"}" 2>&1
    )"; then
      curl_rc=0
    else
      curl_rc=$?
    fi

    http_code="$(echo "$resp" | tail -n1)"
    body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" -eq 200 ]]; then
      log "Salt minion key accepted"
      restart_salt_minion_or_die
      return 0
    fi

    if [[ "$http_code" == "400" ]] && echo "$body" | grep -qi "Minion Already Exists"; then
      log "Salt minion key already exists on master; treating the accept operation as idempotent success"
      restart_salt_minion_or_die
      return 0
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

    if [[ "$curl_rc" -eq 28 ]]; then
      warn "Salt API accept request timed out after ${API_MAX_TIME}s; the master may still complete it, retrying"
    else
      warn "Salt API returned HTTP ${http_code}: ${body}"
    fi
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
  install_md_gpupdate
  refresh_api_token_for_salt

  log "Checking DNS resolution: SALT_MASTER=${SALT_MASTER}"
  getent hosts "${SALT_MASTER}" >/dev/null || die "DNS resolution failed for ${SALT_MASTER}"

  gpo_token="$(
    curl -sS -X GET "https://${API_HOST}/api/salt/master/key" \
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
  SALT_MINION_ID="$guid"

  prepare_salt_minion_identity "$guid" "$gpo_token"

  restart_salt_minion_and_wait 8
  accept_salt_minion_key "$guid"
}
