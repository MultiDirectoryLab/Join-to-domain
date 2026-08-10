api_delete_salt_minion_key() {
  local cookie="$1"
  local minion_id="$2"
  local resp http_code body

  [[ -n "$minion_id" ]] || return 0
  if [[ ! "$minion_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
    warn "Salt minion id is not a UUID (${minion_id}); UUID deletion endpoint skipped"
    return 0
  fi

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

  if [[ ! "$guid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
    warn "Salt minion id is not a UUID (${guid}); UUID deletion endpoint skipped"
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

detect_salt_pkg_provider() {
  if is_altlinux; then
    # The bundled extension module is installed as pkg.py and implements the
    # apt-rpm combination used by ALT Linux.
    printf '%s\n' pkg
  elif is_deb_based; then
    printf '%s\n' aptpkg
  elif have_cmd dnf || have_cmd yum; then
    printf '%s\n' yumpkg
  elif have_cmd apt-get; then
    printf '%s\n' aptpkg
  else
    return 1
  fi
}

configure_salt_pkg_provider() {
  local provider
  local provider_file="/etc/salt/minion.d/pkg_provider.conf"

  if ! provider="$(detect_salt_pkg_provider)"; then
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

configure_salt_master_health() {
  local health_file="/etc/salt/minion.d/99-master-health.conf"

  mkdir -p "$(dirname -- "$health_file")"
  md_backup_once "$health_file"

  {
    printf 'master_alive_interval: 10\n'
    printf 'master_tries: -1\n'
    printf 'retry_dns: 5\n'
  } > "$health_file"

  chmod 0644 "$health_file"
  md_track "$health_file"
  log "Configured Salt master health checks: ${health_file}"
}

prepare_salt_minion_identity() {
  local guid="$1"
  local gpo_token="$2"
  local existing_minion_id=""

  require_salt_minion_ready

  log "Preparing Salt minion identity: ${guid}"

  systemctl stop salt-minion.service 2>/dev/null || true
  if pgrep -x salt-minion > /dev/null 2>&1; then
    pkill -TERM -x salt-minion 2>/dev/null || true
    sleep 2
    if pgrep -x salt-minion > /dev/null 2>&1; then
      warn "$(ui_text "Some salt-minion processes still remain, killing again..." "Некоторые процессы salt-minion не остановились; выполняется принудительная остановка...")"
      pkill -KILL -x salt-minion 2>/dev/null || true
      sleep 1
    fi
    log "Salt processes stopped"
  fi

  if [[ -f /etc/salt/minion_id ]]; then
    existing_minion_id="$(tr -d '\r\n' < /etc/salt/minion_id 2>/dev/null || true)"
    if [[ -n "$existing_minion_id" && "$existing_minion_id" != "$guid" ]]; then
      info "$(ui_text "Updating Salt minion id from ${existing_minion_id} to ${guid}; keeping the existing minion key pair" "Идентификатор Salt minion меняется с ${existing_minion_id} на ${guid}; существующая пара ключей сохраняется")"
      if [[ "$existing_minion_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
        log "Deleting the previous Salt minion id before publishing the new one: ${existing_minion_id}"
        api_delete_salt_minion_key "${access_token}" "${existing_minion_id}"
      else
        info "Previous Salt minion id is not a UUID (${existing_minion_id}); deletion via the UUID endpoint is not required"
        log "Skipped deletion of incompatible legacy Salt minion id: ${existing_minion_id}"
      fi
    fi
  fi

  mkdir -p /etc/salt

  md_backup_once /etc/salt/minion
  md_backup_once /etc/salt/pki/minion
  md_track /etc/salt/pki/minion

  cat > /etc/salt/minion <<EOF
master: ${SALT_MASTER}
master_finger: ${gpo_token}
EOF

  md_track /etc/salt/minion

  if [[ -d /etc/salt/minion.d ]]; then
    while IFS= read -r -d '' salt_conf; do
      if grep -Eq '^[[:space:]]*(master|master_finger|id)[[:space:]]*:' "$salt_conf" 2>/dev/null; then
        md_backup_once "$salt_conf"
        sed -i -E '/^[[:space:]]*(master|master_finger|id)[[:space:]]*:/d' "$salt_conf"
        md_track "$salt_conf"
      fi
    done < <(find /etc/salt/minion.d -type f -name '*.conf' -print0)
  fi

  echo "$guid" > /etc/salt/minion_id
  chmod 0644 /etc/salt/minion_id
  md_track /etc/salt/minion_id

  configure_salt_pkg_provider
  configure_salt_master_health

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

salt_minion_master_connected() {
  local output=""

  systemctl is-active --quiet salt-minion.service 2>/dev/null || return 1
  have_cmd salt-call || return 1

  if have_cmd timeout; then
    output="$(timeout 6 salt-call --local --out=txt status.master "$SALT_MASTER" 2>/dev/null || true)"
  else
    output="$(salt-call --local --out=txt status.master "$SALT_MASTER" 2>/dev/null || true)"
  fi

  printf '%s\n' "$output" | grep -Eqi '(^[[:space:]]*true|:[[:space:]]*true)[[:space:]]*$'
}

wait_for_salt_minion_master_connection() {
  local attempts="${1:-6}"
  local delay="${2:-2}"
  local attempt=1

  while (( attempt <= attempts )); do
    if salt_minion_master_connected; then
      log "Salt minion has an established connection to ${SALT_MASTER}:4505"
      return 0
    fi

    if (( attempt < attempts )); then
      sleep "$delay"
    fi
    ((attempt++))
  done

  return 1
}

confirm_salt_accept_result() {
  local result_description_en="$1"
  local result_description_ru="$2"

  restart_salt_minion_or_die
  if wait_for_salt_minion_master_connection 10 2; then
    log "Salt minion connection confirmed after ${result_description_en}"
    return 0
  fi

  warn "$(ui_text "${result_description_en}, but the minion connection to ${SALT_MASTER}:4505 was not confirmed" "${result_description_ru}, но соединение minion с ${SALT_MASTER}:4505 не подтверждено")"
  return 1
}

accept_salt_minion_key() {
  local guid="$1"
  local resp http_code body curl_rc
  local retries=8
  local delay=3
  local attempt=1

  while [[ $attempt -le $retries ]]; do
    log "Attempt ${attempt}/${retries}: accepting Salt minion key"

    if resp="$(
      curl -sS -w "\n%{http_code}" \
        --connect-timeout "${SALT_ACCEPT_CONNECT_TIMEOUT}" \
        --max-time "${SALT_ACCEPT_MAX_TIME}" \
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

    if [[ "$http_code" == "200" ]]; then
      log "Salt minion key accepted"
      if confirm_salt_accept_result "Salt API accepted the minion key" "Salt API принял ключ minion"; then
        return 0
      fi
      print_salt_diagnostics
      warn "$(ui_text "Check TCP access from the minion to ${SALT_MASTER} on ports 4505 and 4506" "Проверьте доступ с minion к ${SALT_MASTER} по TCP-портам 4505 и 4506")"
      die "$(ui_text "The Salt key was accepted, but the minion did not connect to the master" "Ключ Salt принят, но minion не подключился к master")"
    fi

    if [[ "$http_code" == "400" ]] && echo "$body" | grep -qi "Minion Already Exists"; then
      log "Salt minion key already exists on master; verifying the actual minion connection"
      if confirm_salt_accept_result "Salt API reports that the minion already exists" "Salt API сообщает, что minion уже существует"; then
        return 0
      fi
      print_salt_diagnostics
      warn "$(ui_text "Check TCP access from the minion to ${SALT_MASTER} on ports 4505 and 4506" "Проверьте доступ с minion к ${SALT_MASTER} по TCP-портам 4505 и 4506")"
      die "$(ui_text "The Salt key exists, but the minion did not connect to the master" "Ключ Salt существует, но minion не подключился к master")"
    fi

    if [[ "$http_code" == "400" ]] && echo "$body" | grep -qi "Unable to accept minion"; then
      warn "$(ui_text "Salt key is not ready on master yet. Waiting before retry." "Ключ Salt ещё не появился на мастере. Ожидание перед повторной попыткой.")"
      sleep "$delay"

      if (( attempt % 3 == 0 )); then
        warn "$(ui_text "Restarting salt-minion to force key publication" "Перезапуск salt-minion для повторной публикации ключа")"
        restart_salt_minion_and_wait 8
      fi

      ((attempt++))
      continue
    fi

    if [[ "$curl_rc" -eq 28 ]]; then
      info "$(ui_text "Salt API response timed out after ${SALT_ACCEPT_MAX_TIME}s; checking whether the key was accepted anyway" "Ответ Salt API не получен за ${SALT_ACCEPT_MAX_TIME} с; проверяется, был ли ключ всё же принят")"
      # The MultiDirectory endpoint waits for the accepted minion to appear in
      # Salt. Restarting here forces an immediate authentication attempt instead
      # of waiting for the minion's normal authentication retry interval.
      log "Restarting salt-minion after API timeout to force immediate re-authentication"
      restart_salt_minion_or_die
      if wait_for_salt_minion_master_connection 5 2; then
        log "Salt minion connection confirmed after an API response timeout"
        return 0
      fi
      warn "$(ui_text "Salt minion connection is not confirmed yet; retrying the API request" "Соединение Salt minion пока не подтверждено; запрос к API будет повторён")"
    else
      warn "$(ui_text "Salt API returned HTTP ${http_code}: ${body}" "Salt API вернул HTTP ${http_code}: ${body}")"
    fi
    sleep "$delay"
    ((attempt++))
  done

  print_salt_diagnostics
  warn "$(ui_text "Check TCP access from the minion to ${SALT_MASTER} on ports 4505 and 4506" "Проверьте доступ с minion к ${SALT_MASTER} по TCP-портам 4505 и 4506")"
  die "$(ui_text "Failed to accept Salt minion key" "Не удалось принять ключ Salt minion")"
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
  install_salt_custom_modules
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
